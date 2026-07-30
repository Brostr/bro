---
name: dispute-resolution
description: Dispute resolution and auto-liquidation system for the Bro app. Use when modifying dispute flows, auto-liquidation timers, AI dispute agent, evidence handling, collateral/escrow, or any code in dispute_service.dart, dispute_detail_screen.dart, disputeAgentService.js, agent.js, or escrow.js. Prevents data loss from encrypted evidence, incorrect timer thresholds, and agent misconfiguration.
---

# Dispute Resolution — Bro App

## Purpose

Prevents bugs in dispute creation, evidence exchange, auto-liquidation, and AI agent analysis. Documents the exact event flow, encryption requirements, timer thresholds, and agent tiers.

## When to Use

Activate when:
- Modifying dispute creation or resolution
- Changing auto-liquidation timers or logic
- Touching AI dispute agent configuration
- Modifying evidence upload/decryption
- Changing escrow/collateral logic
- Modifying `dispute_detail_screen.dart`
- Touching `disputeAgentService.js` or `agent.js`

## Dispute Flow

```
1. User/Provider opens dispute
   → publishDisputeNotification() (kind 1, tag #t='bro-disputa')
   → Push notify counterparty (subtype: 'disputed')

2. Backend detects via NostrListener
   → disputeAgent.analyzeDispute() triggered

3. Evidence exchange (optional)
   → publishDisputeEvidence() (kind 1, NIP-44 encrypted)
   → Agent re-analyzes on new evidence

4. Admin reviews in dispute_detail_screen.dart
   → Sees agent recommendation + confidence
   → Approves or overrides

5. Resolution published
   → publishDisputeResolution() (kind 1 + kind 30080 audit)
   → Loser tagged: #t='bro-dispute-loser-{pubkey}'
```

## Event Kinds & Tags

| Event | Kind | Key Tags | Encryption |
|-------|------|----------|------------|
| Dispute notification | 1 | `#t='bro-disputa'`, `#r=orderId`, `#p=[admin, provider]` | NIP-44 evidence |
| Dispute evidence | 1 | `#t='bro-disputa-evidencia'`, `#r=orderId`, `#p=[admin]` | Full NIP-44 (sender→**admin**) |
| Normal comprovante | 30081 | `#d='{orderId}_complete'`, `#t='bro-complete'`, field `proofImage_nip44` | NIP-44 (sender→**user only**, since v444) |
| Dispute resolution | 1 | `#t='bro-resolucao'`, `#t='bro-dispute-loser-{pubkey}'` | None |
| Resolution audit | 30080 | `#d='{orderId}_resolution'` | None |

## Encryption Rules

**ALL dispute evidence MUST be NIP-44 encrypted (`senderPrivateKey → adminPubkey`).**

- Proof images: base64 encoded, encrypted with NIP-44
- Evidence descriptions: encrypted with NIP-44
- Resolution notes: NOT encrypted (public record)
- Image size warning: >45KB base64 may fail on some relays (nos.lol rejects >72KB)

## Mediator Role & Identity Model (CRITICAL)

The mediator/admin is a **third party**, not the buyer or seller. Understanding *what a mediator can and cannot read* is essential.

### Two DIFFERENT proof channels — don't confuse them

| Channel | Event | Encrypted to | Mediator can read? |
|---------|-------|--------------|--------------------|
| **Normal comprovante** (provider → user, happy path) | kind **30081** `bro_complete`, tag `#d='{orderId}_complete'`, field `proofImage_nip44` | **ONLY the user** (since v444 — admin/provider copies were dropped to keep event under relay size limits) | ❌ **NO** — mediator canNOT decrypt the normal comprovante |
| **Dispute evidence** (any party → admin, during a dispute) | kind **1**, tag `#t='bro-disputa-evidencia'`, `#r=orderId` | **ADMIN_PUBKEY** (`AppConfig.adminPubkey` from env.json) | ✅ **YES** — but only if logged in as that exact identity |

> **Consequence:** A provider who sent a comprovante only through the *happy-path* flow (kind 30081) has NOT given the mediator anything readable. The mediator can only prove the comprovante EXISTS (event present, status reached `awaiting_confirmation`), not read its contents. To have the mediator review the actual image, the party must **re-send it as dispute evidence** (kind 1, encrypted to admin).

### The HMAC / "0 evidências" gotcha

Dispute evidence is encrypted to a **fixed** `ADMIN_PUBKEY` baked into the build (env.json). But admin access in the app is gated by a **PASSWORD** (`settings_screen._validateAdminPassword`), NOT by pubkey. So **any** logged-in Nostr identity can open the admin screen, but only the identity whose private key matches `ADMIN_PUBKEY` can decrypt the evidence.

- If the logged-in identity ≠ `ADMIN_PUBKEY` → NIP-44 decryption throws **"HMAC inválido - mensagem pode ter sido adulterada"** → evidence appears as "0 evidências" / locked.
- **Fix path:** log in with the nsec/seed whose pubkey == `ADMIN_PUBKEY`, OR update `ADMIN_PUBKEY` in env.json to the real mediator identity and rebuild (⚠️ past evidence encrypted to the old pubkey becomes permanently unreadable).
- To verify which identity is logged in on a debuggable device: the pubkey is in `shared_prefs/FlutterSharedPreferences.xml` (public, safe). The nsec is in `FlutterSecureStorage.xml` (Android-Keystore encrypted — never extract).

### `fetchDisputeEvidence` must NOT silently drop undecryptable evidence

`orderId`, `type`, and `senderRole` live INSIDE the encrypted payload. Historically, when decryption failed, the guard `if (content['orderId'] == orderId && content['type'] == 'bro_dispute_evidence')` failed (both undefined) and the evidence was **dropped silently** → mediator saw "0 evidências" even though events existed on the relay.

**Correct behavior (current):** when decryption fails, return a **metadata record** from the envelope — `senderPubkey`, `created_at`→`sentAt`, `encrypted: true`, `decryptable: false`, plus a placeholder description. The admin UI then shows the evidence with a 🔒 lock icon and infers the role by matching `senderPubkey` to `userPubkey`/`providerId`. Never drop evidence just because the current identity can't decrypt it.

## Order Status Flow (what the mediator sees)

```
pending
  → payment_received   (escrow funded; providerId may still be null)
  → accepted           (provider accepted, kind 30079)
  → [provider sends comprovante via kind 30081 bro_complete]
  → awaiting_confirmation  ("📸 Comprovante recebido! Verifique e confirme o pagamento")
  → [USER confirms]
  → completed          (platform fee fires ONLY here)

Any party may branch to:  disputed
```

Reading the timeline from relays lets the mediator locate exactly where an order stalled:

- **Stuck at `accepted`, NO kind 30081 exists** → provider never submitted a comprovante through the flow.
- **Reached `awaiting_confirmation`** → provider DID publish a kind 30081 comprovante; the order is waiting on the user to confirm. This is the admin's "confirme pagamento" state.
- **`completed`** → user confirmed; platform fee (`PlatformFeeService.sendPlatformFee`) was sent. If an order never reached `completed`, it should NOT have generated a platform fee.

## Mediation Reconciliation Checklist

When concluding a dispute, reconstruct from relays and check, in order:

1. **Identify the parties** — order creator pubkey (`#d` order event) and provider pubkey (kind 30079 accept).
2. **Locate the stall point** — walk kinds 30078/30079/30080/30081 by `created_at`; determine last status reached.
3. **Who opened the dispute and when** — kind 1 `#t='bro-disputa'`; compare its timestamp to the payment/comprovante timeline.
4. **Was a comprovante submitted?** — presence of kind 30081 = yes (happy path, mediator can't read image); dispute-evidence (kind 1 to admin) = readable if logged in as ADMIN_PUBKEY.
5. **Verify the comprovante content** (if readable) — PIX end-to-end ID / boleto authentication code, payer/payee names, exact amount, date/time — all must match the order.
6. **Timing logic** — e.g. if the user requested cancellation BEFORE the provider paid, the provider should not pay; if the provider paid BEFORE a valid cancellation, the user owes.
7. **Recidivism** — count `bro-dispute-loser-{pubkey}` tags for each party.
8. **Decide & publish** — `publishDisputeResolution()` (kind 1 + kind 30080 audit), tagging the loser.

## AI Dispute Agent

### Tier System

| Tier | Confidence | Action | Limit |
|------|-----------|--------|-------|
| Tier 1 (Auto) | >90% | Auto-resolve | Max 20/day |
| Tier 2 (Suggest) | 60-90% | Show recommendation to admin | Unlimited |
| Tier 3 (Escalate) | <60% | Flag for human review only | Unlimited |

### Analysis Pipeline

```
1. Heuristic rules (instant)
   ├─ No evidence from disputer → lean toward counterparty
   ├─ Recidivist check (dispute-loser tag count) → lower trust
   ├─ Extreme amounts → escalate
   └─ FX volatility check → adjust confidence

2. LLM fallback (if heuristic <90%)
   └─ Claude analyzes: reason, description, amounts, evidence flags
      Returns: suggestion, confidence, reasoning
```

### Configuration (disputeAgentService.js)

```javascript
autoResolveThreshold: 0.90,
suggestThreshold: 0.60,
maxAutoResolvesPerDay: 20,
maxDisputeAgeSecs: 7 * 24 * 3600,  // 7 days
llmProvider: 'anthropic',
llmModel: 'claude-sonnet-4-20250514',
```

### Agent Routes (backend/routes/agent.js)

All require NIP-98 auth + ADMIN_PUBKEY:
- `GET /agent/status` — Agent stats and tier distribution
- `GET /agent/pending` — List pending dispute analyses
- `GET /agent/analysis/:orderId` — Get analysis for specific order
- `POST /agent/approve` — Admin approves agent suggestion
- `POST /agent/reject` — Admin rejects with own decision
- `POST /agent/analyze` — Manual analysis trigger

## Auto-Liquidation

### Timer Rules

- **Trigger:** Order in `awaiting_confirmation` for 36 hours after proof submission
- **Proof timestamp source:** `receipt_submitted_at` → `proofReceivedAt` → Nostr event `created_at`
- **NEVER use `DateTime.now()` or `updatedAt`** — these are sync time, not proof time (v505 lesson)

### Auto-Liquidation Flow

```
1. _checkAutoLiquidation() runs in foreground poll
2. Filters: status == 'awaiting_confirmation' && 36h elapsed
3. Checks autoLiquidated flag (prevent duplicates)
4. Publishes 'liquidated' status via Nostr
5. Triggers auto-payment to provider via collateral
```

### Background Auto-Liquidation

`background_notification_service.dart` also checks auto-liquidation every 15 minutes.
Uses lock mechanism (`_bgAutoLiqLockKey`) to prevent race with foreground.

## Collateral/Escrow (Provider Tiers)

| Tier | Guarantee (BRL) | Limit/Order (BRL) |
|------|-----------------|-------------------|
| trial | R$ 10 | R$ 10 |
| starter | R$ 50 | R$ 50 |
| basic | R$ 200 | R$ 200 |
| intermediate | R$ 500 | R$ 500 |
| advanced | R$ 1.000 | R$ 1.000 |
| master | R$ 3.000 | Unlimited |

**Beta limit:** `maxTierLimitBrl = 200.0` (Básico tier max)

## Status Transition Rules

- `cancelled` is TERMINAL ABSOLUTE — only `disputed` can override it
- `disputed` can transition to `completed` or `cancelled` (mediation resolution)
- `disputed` overrides non-terminal statuses
- `liquidated` is terminal — cannot be changed

## Known Gaps for Future Improvement

1. **No image analysis** — Agent only sees flags (has_proof: yes/no), not actual images
2. **No PIX/Boleto API verification** — Cannot verify if bill was actually paid
3. **No dispute velocity tracking** — Only counts total losses, not recency
4. **No Claude Vision integration** — Proof screenshots not analyzed by LLM

## Bug Patterns — DON'T REPEAT

1. **Timer using sync time instead of event time** — Always use `receipt_submitted_at` from Nostr event `created_at`
2. **Double auto-liquidation** — Always check `autoLiquidated` flag before publishing
3. **Background/foreground race** — Use lock mechanism with 2-minute TTL
4. **Evidence image too large** — Warn user if base64 > 45KB, relay may reject silently
5. **Dropping undecryptable evidence** — `fetchDisputeEvidence` must return envelope metadata (senderPubkey, sentAt, `decryptable:false`) when NIP-44 decryption fails, NEVER discard the event. `orderId`/`type`/`senderRole` are inside the ciphertext, so the old guard silently hid evidence when the logged-in identity ≠ ADMIN_PUBKEY.
6. **Confusing the two proof channels** — The normal comprovante (kind 30081) is encrypted to the USER only; the mediator can prove it exists but cannot read it. Only dispute evidence (kind 1 → admin) is mediator-readable.

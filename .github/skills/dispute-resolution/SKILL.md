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
| Dispute evidence | 1 | `#t='bro-disputa-evidencia'` | Full NIP-44 (sender→admin) |
| Dispute resolution | 1 | `#t='bro-resolucao'`, `#t='bro-dispute-loser-{pubkey}'` | None |
| Resolution audit | 30080 | `#d='{orderId}_resolution'` | None |

## Encryption Rules

**ALL dispute evidence MUST be NIP-44 encrypted (`senderPrivateKey → adminPubkey`).**

- Proof images: base64 encoded, encrypted with NIP-44
- Evidence descriptions: encrypted with NIP-44
- Resolution notes: NOT encrypted (public record)
- Image size warning: >45KB base64 may fail on some relays (nos.lol rejects >72KB)

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

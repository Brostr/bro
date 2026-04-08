---
name: fcm-push
description: FCM push notification architecture for the Bro app. Use when modifying push notifications, FCM token registration, APNS configuration, background message handling, or any code in pushService.js, brix_relay_service.dart, background_notification_service.dart, or main.dart FCM sections. Prevents recurring bugs with iOS delivery, token lifecycle, and notification types.
---

# FCM Push Notification — Bro App

## Purpose

This skill prevents recurring push notification bugs by documenting the EXACT architecture, platform requirements, and lessons learned from production incidents. **Read this BEFORE modifying any push-related code.**

## When to Use

Activate when:
- Modifying `backend/services/pushService.js`
- Modifying `backend/routes/push.js`
- Touching FCM code in `lib/main.dart`
- Modifying `lib/services/brix_relay_service.dart` (FCM registration)
- Modifying `lib/services/background_notification_service.dart`
- Adding/changing push notification types
- Debugging "push not arriving" issues
- Changing APNS headers or payload structure

## Architecture Overview

### Two Independent Push Systems

The app registers FCM tokens with TWO separate servers:

| Server | Purpose | Endpoint | Auth |
|--------|---------|----------|------|
| **Backend** (`api.brostr.app`) | Order updates (accepted, proof, complete, dispute) | `POST /push/register-token` | NIP-98 |
| **BRIX** (`brix.brostr.app`) | Invoice requests for incoming payments | `POST /brix/register-push` | NIP-98 |

Both registrations are **independent** — one can succeed while the other fails.

### Two Notification Types — NEVER MIX THEM

| Type | FCM Payload | iOS Behavior | When Used |
|------|------------|--------------|-----------|
| `order_update` | `notification` + `data` | System shows notification even in background | Order accepted, proof submitted, completed, disputed, cancelled |
| `brix_invoice_request` | `data` ONLY | Silent background processing via `content-available: 1` | Incoming BRIX payment needs invoice |

**CRITICAL RULES:**
- `brix_invoice_request` MUST be data-only — it needs silent background execution to generate a Spark invoice. Adding `notification` would break this.
- `order_update` MUST include `notification` field — this guarantees iOS shows it even when the app is suspended/killed.

## iOS APNS Requirements

### Required Headers (in pushService.js)

```javascript
apns: {
  headers: {
    'apns-priority': '10',
    'apns-push-type': 'background',  // DEFAULT for data-only
  },
  payload: {
    aps: {
      'content-available': 1,  // ALWAYS required for background processing
    },
  },
}
```

### When notification is present (order_update):

```javascript
// MUST override push-type to 'alert'
message.apns.headers['apns-push-type'] = 'alert';
message.apns.payload.aps = {
  alert: { title: '...', body: '...' },
  sound: 'default',
  'content-available': 1,
};
```

### iOS Push Type Rules (Apple requirement)

| `apns-push-type` | When to Use | What Happens if Wrong |
|-------------------|-------------|----------------------|
| `background` | Data-only pushes (BRIX) | iOS silently drops the push |
| `alert` | Pushes with notification/alert | iOS may reject or not display |

**LESSON LEARNED (v505):** Without explicit `apns-push-type`, iOS can miscategorize pushes and silently ignore them. Always set it explicitly.

## Token Registration Lifecycle

### Three Registration Points (redundancy by design)

1. **App startup** (`main.dart`): `_retryAsync` with 3 attempts + exponential backoff (2s, 4s, 8s)
2. **BrixRelayService polling loop** (`brix_relay_service.dart`): Retries every ~30 seconds INDEFINITELY until both servers confirm
3. **Background worker** (`background_notification_service.dart`): Workmanager runs every 15 minutes, refreshes token with both servers

### Why Three Points?

**LESSON LEARNED (v504):** Having only startup registration (even with 3 retries) is NOT enough. If the network is unavailable during the ~8 second startup window, the token is NEVER registered. The BrixRelayService's infinite retry loop was added because:
- BRIX had retry → BRIX push always worked
- Backend had startup-only → Backend push silently failed for days
- Carol's iOS device had NO backend token for the entire testing period

### Registration State Flags

```dart
bool _fcmRegistered = false;       // BRIX server
bool _backendFcmRegistered = false; // Main backend
```

Both reset to `false` on:
- `start()` — Initial start
- `restart()` — App resume from background
- `resetFcmRegistration()` — Token refresh event

### Token Refresh Flow

```
Firebase rotates token → onTokenRefresh listener fires
  → Register with BRIX server
  → Register with Backend
  → BrixRelayService.resetFcmRegistration()
    → Next poll cycle re-registers with both servers
```

## Backend pushService.js — sendPush()

```javascript
async function sendPush(targetPubkey, data, notification = null)
```

**Key rules:**
- `data` values MUST all be strings (FCM requirement)
- `notification` parameter: pass `null` for BRIX, pass `{title, body}` for order_update
- Invalid tokens are auto-removed on `messaging/registration-token-not-registered` error
- Token lookup is by pubkey (can have multiple tokens per pubkey)
- Token storage: in-memory Map + disk persistence with 90-day cleanup

## push.js Routes

### POST /push/register-token
- Auth: NIP-98 (kind 27235)
- Body: `{ fcm_token }` (100-4096 chars, base64url-safe)
- Rate limit: 5/minute
- Returns: `{ ok, push_enabled }`

### POST /push/notify
- Auth: NIP-98
- Body: `{ target_pubkey, type, subtype?, order_id? }`
- Types: `order_update` | `brix_invoice_request`
- Rate limit: 10/minute
- Only `order_update` gets notification field (with emoji-mapped subtypes)

## Order Update Subtypes & Emojis

| Subtype | Emoji | Notification |
|---------|-------|-------------|
| `accepted` | ✅ | "Order Accepted" |
| `payment_proof` | 📸 | "Payment Proof Received" |
| `completed` | 🎉 | "Order Completed" |
| `disputed` | ⚠️ | "Order Disputed" |
| `cancelled` | ❌ | "Order Cancelled" |

## Background Notification Service

`background_notification_service.dart` runs via Workmanager every 15 minutes:
- Reads keypair from FlutterSecureStorage
- Gets fresh FCM token
- Creates NIP-98 auth event
- Registers with BOTH servers (10s timeout each)
- URL validation: HTTPS only, `*.brostr.app` domain allowlist

## Common Bug Patterns — DON'T REPEAT

### 1. Fire-and-forget registration
**Wrong:** Register once, ignore failure
**Right:** Retry indefinitely via BrixRelayService loop + background worker

### 2. Missing APNS push-type header
**Wrong:** Let FCM SDK guess the push type
**Right:** Always set `apns-push-type` explicitly (`background` or `alert`)

### 3. Adding notification to BRIX push
**Wrong:** Adding `notification` field to `brix_invoice_request` for "better delivery"
**Right:** BRIX MUST be data-only — it needs silent execution to generate invoices

### 4. Removing notification from order_update
**Wrong:** Making order_update data-only "for consistency"
**Right:** order_update NEEDS notification+data — iOS won't wake killed apps for data-only

### 5. Token registered with BRIX but not backend (or vice versa)
**Symptom:** BRIX push works but order push doesn't (or vice versa)
**Cause:** Independent registration — one can fail while other succeeds
**Fix:** Both flags must be true: `_fcmRegistered && _backendFcmRegistered`

### 6. Not resetting registration on app resume
**Wrong:** Assuming token from startup is still valid after hours in background
**Right:** Reset both flags on `restart()` so next poll re-registers

## Debugging Checklist

When push notifications aren't arriving:

1. **Check backend logs** (Fly.io): `fly logs -a bro-api | grep PUSH`
   - `[PUSH] No token for <pubkey>` → Token not registered
   - `[PUSH] Sent to <pubkey>` → Server sent successfully, problem is client-side

2. **Check registered tokens**: `GET https://api.brostr.app/push/status`

3. **Check app logs**: Look for `[BRIX-RELAY] FCM token registered successfully (backend)` and `(BRIX)`

4. **iOS-specific**: Check `apns-push-type` header matches payload type

5. **Token freshness**: Force kill app, reopen, check if token re-registers within 30s

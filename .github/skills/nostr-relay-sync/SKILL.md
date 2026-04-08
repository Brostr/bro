---
name: nostr-relay-sync
description: Nostr relay synchronization architecture for the Bro app. Use when modifying relay connections, order sync logic, event fetching, WebSocket management, or any code in nostr_order_service.dart relay sections, nostr_service.dart, relay_service.dart, or OrderRealtimeService. Prevents event loss, sync races, subscription leaks, and relay-specific silent failures.
---

# Nostr Relay Sync — Bro App

## Purpose

Prevents sync bugs, event loss, and relay-specific failures. Documents the exact relay architecture, connection strategy, caching, and known relay quirks.

## When to Use

Activate when:
- Modifying relay connection or WebSocket code
- Changing order sync logic or event fetching
- Adding/removing relays
- Modifying subscription management
- Debugging "order not showing" or "status not updating" issues
- Touching `nostr_order_service.dart` fetch methods
- Modifying `OrderRealtimeService` or `relay_service.dart`

## Relay Configuration

### Primary Relays (hardcoded)

```dart
const List<String> relays = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
];
```

### Background Worker Relays

```dart
const List<String> _relays = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://relay.nostr.band',  // fallback only
];
```

## Connection Architecture

### Ephemeral WebSockets (NO connection pool)

Each operation creates a NEW WebSocket, uses it, and closes it:
```
fetchOrderUpdatesForUser() → opens 3 WebSockets (one per relay) → closes all
publishOrderToNostr() → opens 3 WebSockets → publishes → closes all
```

**Why ephemeral:** Simpler, no keepalive complexity, no stale connection bugs.
**Tradeoff:** ~500ms overhead per operation for new connection handshake.

### Connection Timeouts

| Operation | Connect Timeout | Response Timeout | Total Max |
|-----------|----------------|-----------------|-----------|
| Fetch events | 8s per relay | 10s total | ~18s |
| Publish event | 4s connect | 15s response | ~19s |
| Background fetch | 5s connect | 8s per relay | ~13s |

### WebSocket Cleanup

All connections are properly closed in `try/finally` blocks:
```dart
try {
  channel = WebSocketChannel.connect(Uri.parse(relay));
  // ... use channel ...
} finally {
  await channel?.sink.close();
}
```

CLOSE messages are sent for every subscription (NIP-01 compliant).

## Sync Strategy

### Multi-Relay Query (ALL relays, NOT early-exit)

**CRITICAL RULE (v500 fix):** ALWAYS query ALL relays completely. Never stop at the first relay that returns data.

```
❌ WRONG (pre-v500): Query relay1 → got data → skip relay2 & relay3
✅ RIGHT (v500+):    Query relay1 + relay2 + relay3 → merge all results
```

**Why:** Events are NOT guaranteed to be on all relays. A kind 30081 (proof) might only be on `relay.primal.net` while kind 30079 (accept) is on `relay.damus.io`. Querying only one relay loses events.

### Triple Fetch Strategy per Relay

`fetchOrderUpdatesForUser()` uses 3 parallel query strategies per relay:
1. **By `#p` tag** — Events mentioning this pubkey
2. **By `author`** — Events authored by this pubkey
3. **By `#r` tag** — Events referencing known order IDs

Results are deduplicated by event ID.

### Caching

| Cache | TTL | Lock | Purpose |
|-------|-----|------|---------|
| Status updates | 40s | Completer | Prevents 6 concurrent WebSocket connections |
| Proof images | Write-once | None | Never re-fetched per orderId |

### Event Deduplication

Events are deduplicated by Nostr event `id` (hash). The same event from multiple relays is processed only once.

### Proof Accumulation (v406)

Two-pass strategy prevents proof loss:
```
Pass 1: Collect ALL events from ALL relays (including proofs)
Pass 2: Process status updates (proofs already accumulated)
```

Without this, processing a newer status event before the proof event would discard the proof.

## Real-Time Subscription

`OrderRealtimeService` maintains a persistent WebSocket to one relay for live event notifications:
```dart
OrderRealtimeService().start(userPubkey, onEvent: () {
  // Trigger full sync when new event detected
});
```

This supplements the polling-based sync with immediate notifications.

## Event Publishing

### Parallel Relay Publishing

Events are published to ALL relays simultaneously:
```dart
// Publish to all relays in parallel
final futures = relays.map((relay) => _publishToRelay(relay, event));
final results = await Future.wait(futures);
// Success if at least ONE relay accepted
```

### Publish Retry Logic

- 1 retry with 300ms delay on failure
- No exponential backoff for publishes (speed is critical for UX)

## Known Relay Quirks

### nos.lol

- **Rejects events >72KB** — Large proof images fail silently
- **Frequent disconnections** — Backend logs show reconnect every ~10 minutes
- **Rate limiting** — Aggressive for high-frequency subscriptions

### relay.damus.io

- **Slower response** — Higher latency than nos.lol
- **More reliable for storage** — Events persist longer

### relay.primal.net

- **Best for search** — Supports more complex filter combinations
- **May rewrite timestamps** — Check `created_at` consistency

## Bug Patterns — DON'T REPEAT

### 1. Early-exit relay query (v500 bug)
**Wrong:** Stop querying when first relay returns data
**Right:** Always query ALL relays, merge results

### 2. Subscription leak
**Wrong:** Open SUB, process events, forget to send CLOSE
**Right:** Always send CLOSE in `finally` block

### 3. Processing events in relay order instead of timestamp order
**Wrong:** Process events as they arrive from each relay
**Right:** Collect all events, sort by `created_at`, then process

### 4. Proof image > 72KB
**Wrong:** Publish large base64 proof and assume it arrives
**Right:** Check size, warn user, consider compression

### 5. Concurrent sync races
**Wrong:** Multiple sync calls create 6+ WebSocket connections
**Right:** Use Completer lock with TTL cache (40s)

### 6. Status regression from stale relay data
**Wrong:** Accept older status update that overwrites newer one
**Right:** Use status progression rules + timestamp comparison

## Debugging Checklist

When orders aren't syncing or showing stale data:

1. **Check relay connectivity:** Try `wscat -c wss://relay.damus.io`
2. **Check event existence:** Query each relay individually for the order's `#d` tag
3. **Check event size:** If proof image involved, check total event size vs 72KB
4. **Check cache staleness:** 40s TTL cache may serve stale data
5. **Check status progression:** Log the status chain and verify no regression
6. **Check timestamp ordering:** Events from different relays may have different `created_at`

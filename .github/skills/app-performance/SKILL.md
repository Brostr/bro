---
name: app-performance
description: Flutter app performance patterns for the Bro app. Use when modifying state management, widget rebuild logic, polling intervals, image handling, or SharedPreferences usage. Prevents UI jank, unnecessary rebuilds, memory leaks, and main-thread blocking. Consult before touching OrderProvider, HomeScreen, OrderStatusScreen, or BreezProvider.
---

# App Performance — Bro App

## Purpose

Prevents performance regressions, UI jank, and memory leaks. Documents the current state management architecture, known antipatterns, and safe optimization opportunities.

## When to Use

Activate when:
- Modifying `OrderProvider` notify/rebuild logic
- Changing polling intervals or timer behavior
- Modifying proof image loading or caching
- Changing SharedPreferences write patterns
- Adding new providers or state management
- Modifying `HomeScreen` or `OrderStatusScreen` lifecycle
- Debugging UI jank, slow transitions, or ANR reports

## State Management Architecture

### OrderProvider — Core State Holder

- **Debouncing:** 100ms throttle on `notifyListeners()` — coalesces multiple mutations
- **Sync guards:** `_isSyncingUser` / `_isSyncingProvider` flags prevent concurrent syncs
- **Stale sync detection:** Max 60-second lock before force reset
- **Method:** `_immediateNotify()` for urgent updates, `_debouncedNotify()` for batched

### BreezProvider — Wallet State

- Payment events flow through async listener
- No explicit cleanup on app background (SDK handles internally)

### Three Sync Mechanisms (Overlap by Design)

| Mechanism | Trigger | Interval | Purpose |
|-----------|---------|----------|---------|
| Timer polling | `HomeScreen._startOrdersPolling()` | Variable | Periodic background sync |
| Provider listener | `OrderStatusScreen._setupProviderListener()` | On change | Real-time UI updates |
| FCM push | `main.dart onMessage` | Event-driven | Immediate notification of changes |

**RULE:** These SHOULD overlap for reliability. Do NOT remove any of them.

## Main-Thread Operations

### Heavy Operations (potential jank sources)

| Operation | Duration | UI Impact | Mitigation |
|-----------|----------|-----------|------------|
| Order sync (3 relays + decrypt) | 2-5s | "Sincronizando" indicator | Sync guard prevents concurrent |
| Invoice generation (Spark SDK) | 2-5s | Blocking spinner | Sequential, can't parallelize |
| NIP-44 proof decryption | 1-2s | No indicator | Could add loading state |
| SharedPreferences writes | 10-50ms | Micro-stutter | Debounce recommended |

### SharedPreferences Best Practices

```dart
// ❌ WRONG: Write on every mutation
for (final order in orders) {
  await prefs.setString(order.id, json.encode(order));
}

// ✅ RIGHT: Batch writes, debounce
await prefs.setString('orders', json.encode(allOrders));
```

Current `_saveOrders()` writes the full order list as one JSON string — this is correct.
Individual preference writes (settings, flags) are acceptable since they're infrequent.

## Image Handling

### Proof Images

- **Storage:** Base64 in encrypted Nostr events (~500KB max)
- **Cache:** `order_provider._proofImageCache` (write-once per orderId)
- **Decryption:** NIP-44 on-demand, not pre-cached
- **Display:** `Image.memory(bytes)` — full decode to RAM

### Rules for Image Performance

1. **Never re-decode** — Always check `_proofImageCache` first
2. **Never load proof images in list views** — Only on detail screen
3. **Cache is write-once** — Image for an orderId never changes
4. **No thumbnails** — Full resolution only (acceptable for current scale)
5. **Memory:** ~100 orders × 500KB = ~50MB max cache (acceptable)

## Widget Rebuild Rules

### OrderStatusScreen — 3 Update Sources

1. Timer-based poll (`_statusCheckTimer`)
2. OrderProvider listener (real-time on sync)
3. Countdown timer (every 1 second for expiry display)

**RULE:** `setState()` must check if data actually changed before rebuilding:
```dart
// ❌ WRONG
setState(() { _order = newOrder; });

// ✅ RIGHT
if (_order?.status != newOrder?.status || _order?.metadata != newOrder?.metadata) {
  setState(() { _order = newOrder; });
}
```

### HomeScreen — Lifecycle Management

- `WidgetsBindingObserver` restarts relay service on app resume
- Multiple `addPostFrameCallback` for initialization — execute in sequence, not parallel
- Order list rebuilds on every `OrderProvider.notifyListeners()` call

### List Rendering

Current order list size: 5-20 items. Full rebuild on notify is acceptable.
If order count grows significantly (>100), switch to `ListView.builder` with pagination.

## Timer Management

### Active Timers

| Timer | Where | Interval | Cleanup |
|-------|-------|----------|---------|
| BrixRelayService poll | `brix_relay_service.dart` | 1.5s | `stop()` on widget dispose |
| Order status check | `order_status_screen.dart` | Variable | `dispose()` |
| Countdown display | `order_status_screen.dart` | 1s | `dispose()` |
| Orders polling | `home_screen.dart` | Variable | `dispose()` |

**RULE:** Every `Timer.periodic` MUST have a corresponding `timer.cancel()` in `dispose()`.

### StreamSubscription Cleanup

Every `stream.listen()` MUST store the subscription and cancel in `dispose()`:
```dart
StreamSubscription? _sub;

void initState() {
  _sub = someStream.listen((data) { ... });
}

void dispose() {
  _sub?.cancel();
  super.dispose();
}
```

## Memory Leak Prevention

| Source | Risk | Prevention |
|--------|------|-----------|
| WebSocket listeners | LOW | Proper cleanup in try/finally |
| Provider listeners | MEDIUM | Remove in dispose() |
| Timer references | MEDIUM | Cancel in dispose() |
| Proof image cache | LOW | Write-once, capped at ~50MB |
| Breez SDK | LOW | SDK handles own lifecycle |

## Performance Optimization Opportunities

Safe improvements that won't cause bugs:

1. **Add loading indicator for NIP-44 decryption** — Currently no feedback during 1-2s decrypt
2. **Debounce SharedPreferences flag writes** — Batch multiple flag changes
3. **Lazy-load proof images** — Only decrypt when user scrolls to proof section
4. **Add `const` constructors** — Wherever widget trees don't depend on state

**DO NOT attempt:**
- Image compression (breaks proof verification)
- Removing any sync mechanism (all 3 needed for reliability)
- Connection pooling for relays (adds complexity with minimal gain at current scale)
- Background isolate for sync (state sharing complexity outweighs benefit)

## Bug Patterns — DON'T REPEAT

### 1. Setting isLoading=true during background sync (v502 bug)
**Symptom:** Black screen / permanent loading spinner
**Cause:** BRIX polling set `isLoading = true` on BreezProvider, blocking the entire UI
**Rule:** Background operations MUST NOT set global loading state

### 2. Concurrent sync creating 6+ WebSocket connections
**Cause:** `notifyListeners()` triggers multiple listeners that each call sync
**Fix:** Completer lock + 40s TTL cache in `_fetchAllOrderStatusUpdates()`

### 3. Proof image re-fetch on every screen visit
**Cause:** Cache miss due to wrong key format
**Fix:** Write-once cache keyed by orderId, never invalidated

### 4. Timer not cancelled on screen pop
**Cause:** Missing `timer.cancel()` in `dispose()`
**Fix:** Always cancel timers, always check `mounted` before `setState`

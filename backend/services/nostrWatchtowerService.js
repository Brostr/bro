/**
 * nostrWatchtowerService.js — Watches ALL Bro order events on Nostr relays
 * and sends push notifications to relevant parties automatically.
 *
 * This replaces the unreliable app-triggered push model where the sender's
 * app had to call POST /push/notify after publishing each event.
 * Now the server watches relays directly and notifies on every event.
 *
 * Events monitored:
 *   Kind 30078 (bro_order)        → new order → notify all registered users (new order available)
 *   Kind 30079 (bro_accept)       → accepted  → notify order creator
 *   Kind 30080 (bro_order_update) → status    → notify the other party
 *   Kind 30081 (bro_complete)     → completed → notify order creator
 *
 * v508: Initial implementation
 */

const WebSocket = require('ws');
const pushService = require('./pushService');
const { verifyEvent } = require('nostr-tools/pure');

const RELAYS = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
];

// Nostr event kinds for Bro orders
const KIND_ORDER = 30078;
const KIND_ACCEPT = 30079;
const KIND_PAYMENT_PROOF = 30080;
const KIND_COMPLETE = 30081;

// Notification title/body maps
const NOTIFICATION_MAP = {
  'accepted': { title: '🤝 Bro encontrado!', body: 'Um Bro aceitou sua ordem' },
  'payment_submitted': { title: '📸 Comprovante enviado!', body: 'O Bro enviou o comprovante de pagamento' },
  'awaiting_confirmation': { title: '📸 Comprovante recebido!', body: 'Verifique e confirme o pagamento' },
  'completed': { title: '✅ Ordem concluída!', body: 'A transação foi finalizada com sucesso' },
  'cancelled': { title: '❌ Ordem cancelada', body: 'A ordem foi cancelada' },
  'disputed': { title: '⚖️ Disputa aberta', body: 'Uma disputa foi aberta nesta ordem' },
  'liquidated': { title: '⚡ Auto-liquidação', body: 'A ordem foi auto-liquidada' },
  'new_order': { title: '📋 Nova ordem disponível!', body: 'Uma nova ordem de pagamento está disponível' },
};

class NostrWatchtowerService {
  constructor() {
    this._connections = new Map(); // relay → ws
    this._subscriptions = new Map(); // relay → subId
    this._seenEvents = new Set(); // dedup by event id
    this._seenPushes = new Set(); // dedup by orderId+status — ONE push per status per order
    this._reconnectTimers = new Map();
    this._eoseReceived = new Set(); // relays that finished historical catch-up
    this._orderUsers = new Map(); // orderId → userPubkey cache (from bro_order events)
    this._running = false;
    this._stats = { eventsProcessed: 0, pushesSent: 0, pushesFailed: 0, sigFailed: 0 };
    // SECURITY: Rate limit pushes per target pubkey (max 10 per 5 min)
    this._pushRateMap = new Map(); // pubkey → [timestamps]
    this._PUSH_RATE_WINDOW = 5 * 60 * 1000; // 5 minutes
    this._PUSH_RATE_MAX = 10; // max pushes per window per target
    // v540: Dedup persistente por pubkey+orderId+status com TTL 24h.
    // Protege contra flood quando o app estava offline e backend reinicia:
    // evita reenviar para mesma combo ja entregue.
    this._deliveredPushes = new Map(); // key → timestamp
    this._DELIVERED_TTL = 24 * 60 * 60 * 1000; // 24h
  }

  start() {
    if (this._running) return;
    this._running = true;
    console.log('🗼 [Watchtower] Starting order event monitor on', RELAYS.length, 'relays');

    for (const relay of RELAYS) {
      this._connectToRelay(relay);
    }
  }

  stop() {
    this._running = false;
    for (const [, ws] of this._connections) {
      try { ws.close(); } catch (_) { /* ignore */ }
    }
    for (const [, timer] of this._reconnectTimers) {
      clearTimeout(timer);
    }
    this._connections.clear();
    this._subscriptions.clear();
    this._reconnectTimers.clear();
    this._eoseReceived.clear();
    console.log('🛑 [Watchtower] Stopped');
  }

  _connectToRelay(relayUrl) {
    if (!this._running) return;

    try {
      const ws = new WebSocket(relayUrl);

      ws.on('open', () => {
        console.log(`✅ [Watchtower] Connected to ${relayUrl}`);
        this._connections.set(relayUrl, ws);

        const subId = `bro-wt-${Date.now().toString(36)}`;
        this._subscriptions.set(relayUrl, subId);

        // Subscribe to ALL bro-order tagged events from the last 10 minutes
        // Short window to minimize stale events; real-time events arrive after EOSE
        const since = Math.floor(Date.now() / 1000) - 600;

        const req = JSON.stringify(['REQ', subId,
          {
            kinds: [KIND_ORDER, KIND_ACCEPT, KIND_PAYMENT_PROOF, KIND_COMPLETE],
            '#t': ['bro-order'],
            since,
          },
          {
            kinds: [KIND_ACCEPT, KIND_PAYMENT_PROOF, KIND_COMPLETE],
            '#t': ['bro-update'],
            since,
          },
        ]);
        ws.send(req);
      });

      ws.on('message', (data) => {
        try {
          const msg = JSON.parse(data.toString());
          this._handleMessage(relayUrl, msg);
        } catch (_) { /* Non-JSON, ignore */ }
      });

      ws.on('close', () => {
        console.log(`⚠️  [Watchtower] Disconnected from ${relayUrl}`);
        this._connections.delete(relayUrl);
        this._eoseReceived.delete(relayUrl); // Clear EOSE so reconnect skips historical events
        this._scheduleReconnect(relayUrl);
      });

      ws.on('error', (err) => {
        console.error(`❌ [Watchtower] Error on ${relayUrl}:`, err.message);
        try { ws.close(); } catch (_) { /* ignore */ }
      });
    } catch (err) {
      console.error(`❌ [Watchtower] Failed to connect to ${relayUrl}:`, err.message);
      this._scheduleReconnect(relayUrl);
    }
  }

  _scheduleReconnect(relayUrl) {
    if (!this._running) return;
    const delay = 15000 + Math.random() * 10000; // 15-25s
    console.log(`🔄 [Watchtower] Reconnecting to ${relayUrl} in ${Math.round(delay / 1000)}s`);

    const timer = setTimeout(() => {
      this._reconnectTimers.delete(relayUrl);
      this._connectToRelay(relayUrl);
    }, delay);
    this._reconnectTimers.set(relayUrl, timer);
  }

  _handleMessage(relayUrl, msg) {
    if (!Array.isArray(msg)) return;
    const [type, subId, event] = msg;
    
    if (type === 'EOSE') {
      // End of stored events — from now on, events are real-time
      if (!this._eoseReceived.has(relayUrl)) {
        this._eoseReceived.add(relayUrl);
        console.log(`\u2705 [Watchtower] EOSE from ${relayUrl} \u2014 now processing real-time events only`);
      }
      return;
    }
    
    if (type === 'EVENT' && event) {
      this._handleEvent(relayUrl, event);
    }
  }

  async _handleEvent(relayUrl, event) {
    if (!event || !event.id) return;

    // Dedup across relays
    if (this._seenEvents.has(event.id)) return;
    this._seenEvents.add(event.id);

    // Memory management — keep last 5K
    if (this._seenEvents.size > 10000) {
      const arr = Array.from(this._seenEvents);
      this._seenEvents = new Set(arr.slice(-5000));
    }

    // SECURITY: Verify Nostr event signature before trusting ANY data
    // Without this, an attacker could inject fake events to spam push notifications
    try {
      if (!verifyEvent(event)) {
        this._stats.sigFailed++;
        return; // Invalid signature — silently discard
      }
    } catch (_) {
      this._stats.sigFailed++;
      return; // Malformed event
    }

    // Skip events older than 5 minutes (catch-up from subscription, already delivered)
    const eventAge = Math.floor(Date.now() / 1000) - (event.created_at || 0);
    if (eventAge > 300) return;

    // CRITICAL FIX v509: Only process events that arrive AFTER EOSE (real-time)
    // Before EOSE, relays send historical events — these are old orders that should NOT trigger pushes
    // v509b: Per-relay EOSE check — on reconnect, a relay resends historical events before EOSE.
    // Must check THIS relay's EOSE status, not just any relay.
    if (!this._eoseReceived.has(relayUrl)) return; // This relay still in catch-up phase

    let content;
    try {
      content = JSON.parse(event.content);
    } catch (_) {
      return; // Not JSON
    }

    const eventType = content.type;
    const orderId = content.orderId;
    if (!orderId) return;

    // SECURITY: Validate orderId format (UUID) to prevent injection
    if (typeof orderId !== 'string' || orderId.length > 64 || !/^[a-zA-Z0-9_-]+$/.test(orderId)) return;

    // SECURITY: Validate pubkey fields are proper 64-char hex
    const isValidPubkey = (pk) => typeof pk === 'string' && /^[0-9a-f]{64}$/.test(pk);
    if (!isValidPubkey(event.pubkey)) return;

    this._stats.eventsProcessed++;

    const shortId = orderId.substring(0, 8);
    const senderPubkey = event.pubkey;

    try {
      switch (eventType) {
        case 'bro_order': {
          // Cache userPubkey for this order (for later accept/complete events that may omit it)
          const orderUserPubkey = content.userPubkey || senderPubkey;
          if (isValidPubkey(orderUserPubkey)) {
            this._orderUsers.set(orderId, orderUserPubkey);
            // Memory management — keep last 2K orders
            if (this._orderUsers.size > 4000) {
              const entries = Array.from(this._orderUsers.entries());
              this._orderUsers = new Map(entries.slice(-2000));
            }
          }
          // New order created — notify relevant users
          console.log(`🗼 [Watchtower] New order ${shortId} from ${senderPubkey.substring(0, 8)}`);
          await this._notifyNewOrder(senderPubkey, orderId, content, event);
          break;
        }

        case 'bro_accept': {
          // Provider accepted — notify the order creator
          // v512: Fallback to cached userPubkey (provider's accept event may omit userPubkey from content)
          const userPubkeyA = content.userPubkey || this._orderUsers.get(orderId);
          if (isValidPubkey(userPubkeyA) && userPubkeyA !== senderPubkey) {
            await this._sendOrderPush(userPubkeyA, senderPubkey, 'accepted', orderId, shortId);
          } else {
            console.log(`⚠️ [Watchtower] Order ${shortId} accepted but no userPubkey found (content: ${content.userPubkey || 'empty'}, cache: ${this._orderUsers.has(orderId) ? 'hit' : 'miss'})`);
          }
          break;
        }

        case 'bro_order_update': {
          // v512: Status-based routing — route by what the status MEANS, not who published.
          // Both parties publish the same status for sync. Old "notify the other" logic
          // caused BOTH to get notified (echo problem). Now we route by semantics:
          //   - Statuses the USER cares about → always notify user
          //   - Statuses the PROVIDER cares about → always notify provider
          //   - Cancel/dispute → notify the party that didn't initiate
          const status = content.status;
          const userPubkey = content.userPubkey || this._orderUsers.get(orderId);
          const providerId = content.providerId;

          if (!status) break;

          // Cache userPubkey if we see it for the first time
          if (isValidPubkey(userPubkey) && !this._orderUsers.has(orderId)) {
            this._orderUsers.set(orderId, userPubkey);
          }

          // v523: FIX — in Bro's flow, the PROVIDER pays the bill and uploads proof,
          // then the USER verifies proof and releases escrow. So `awaiting_confirmation`
          // (= proof uploaded by provider) MUST notify the USER, not the provider.
          // The old mapping caused background pushes to never reach the user when
          // proof arrived — the screen-level local notification only fired if the
          // app was open and polling. This bug is why "comprovante recebido" only
          // appeared AFTER the user manually released funds.
          //
          // v528: FIX — `completed` is published by the USER (when releasing escrow).
          // It must notify the PROVIDER so they know the payment was released.
          // Previous mapping ('user') caused the self-push guard to block it and
          // the provider silently never got notified via watchtower; only the
          // direct notifyUser() call worked, and that failed too on iOS with the
          // stale backend URL bug. Routing change restores redundancy.
          const STATUS_NOTIFY = {
            'accepted': 'user',              // provider accepted → tell user
            'payment_submitted': 'provider', // user paid Spark invoice → tell provider to execute bill
            'awaiting_confirmation': 'user', // provider uploaded proof → tell user to verify & release
            'completed': 'provider',         // user released escrow → tell provider
            'liquidated': 'user',            // auto-liquidation → tell user (refund)
            'cancelled': 'other',            // tell the party that didn't cancel
            'disputed': 'other',             // tell the party that didn't dispute
          };

          const routing = STATUS_NOTIFY[status] || 'other';
          let targetPubkey = null;

          if (routing === 'user' && isValidPubkey(userPubkey)) {
            targetPubkey = userPubkey;
          } else if (routing === 'provider' && isValidPubkey(providerId)) {
            targetPubkey = providerId;
          } else if (routing === 'other') {
            // Notify the party that DIDN'T publish (for cancel/dispute)
            if (senderPubkey === providerId && isValidPubkey(userPubkey)) {
              targetPubkey = userPubkey;
            } else if (senderPubkey === userPubkey && isValidPubkey(providerId)) {
              targetPubkey = providerId;
            }
          }

          if (targetPubkey) {
            await this._sendOrderPush(targetPubkey, senderPubkey, status, orderId, shortId, routing);
          }
          break;
        }

        case 'bro_complete': {
          // v528: Provider uploaded proof — semantically this is "awaiting_confirmation"
          // (provider finished their part, user now needs to verify & release).
          // Previously this sent label='completed', which:
          //   (a) Showed WRONG message ('Ordem concluída' instead of 'Comprovante recebido')
          //   (b) Set dedup key `orderId:completed` that LATER blocked the real
          //       completed push when the user released escrow.
          // Now uses 'awaiting_confirmation' to match the kind 30080 status semantics
          // and avoid colliding with the user's later completion event.
          const userPubkeyC = content.userPubkey || content.recipientPubkey || this._orderUsers.get(orderId);
          if (isValidPubkey(userPubkeyC) && userPubkeyC !== senderPubkey) {
            await this._sendOrderPush(userPubkeyC, senderPubkey, 'awaiting_confirmation', orderId, shortId);
          } else {
            console.log(`⚠️ [Watchtower] Order ${shortId} completed but no userPubkey found (content: ${content.userPubkey || 'empty'}, recipient: ${content.recipientPubkey || 'empty'}, cache: ${this._orderUsers.has(orderId) ? 'hit' : 'miss'})`);
          }
          break;
        }

        default:
          // Unknown event type, ignore
          break;
      }
    } catch (err) {
      console.error(`❌ [Watchtower] Error processing event ${event.id.substring(0, 8)}: ${err.message}`);
    }
  }

  /**
   * Send push notification for an order status change.
   * v512: Deduplicates by orderId+status (without target) — ONE push per status per order.
   * Both parties publish the same status for sync; only the first event triggers a push.
   */
  async _sendOrderPush(targetPubkey, senderPubkey, status, orderId, shortId, routing) {
    // v523: Never push back to the event's own publisher.
    if (targetPubkey === senderPubkey) return false;

    // v512: Dedup by orderId+status ONLY (no targetPubkey).
    // Both parties publish the same status for sync — only ONE push per status per order.
    // First event to arrive wins; echoes from the other party are suppressed.
    const pushKey = `${orderId}:${status}`;
    if (this._seenPushes.has(pushKey)) return false;
    this._seenPushes.add(pushKey);

    // v514: Log AFTER dedup check so logs reflect actual pushes sent
    const sid = shortId || orderId.substring(0, 8);
    console.log(`🗼 [Watchtower] Order ${sid} → ${status} → PUSH to ${targetPubkey.substring(0, 8)}${routing ? ` (route=${routing})` : ''}`);

    // Memory management — keep last 2K push keys
    if (this._seenPushes.size > 4000) {
      const arr = Array.from(this._seenPushes);
      this._seenPushes = new Set(arr.slice(-2000));
    }

    const notif = NOTIFICATION_MAP[status];
    if (!notif) {
      // Unknown status, send generic
      return this._sendPush(targetPubkey, {
        type: 'order_update',
        sender_pubkey: senderPubkey,
        subtype: status,
        order_id: orderId,
        source: 'watchtower',
      }, { title: '📋 Atualização de ordem', body: `Status: ${status}` });
    }

    return this._sendPush(targetPubkey, {
      type: 'order_update',
      sender_pubkey: senderPubkey,
      subtype: status,
      order_id: orderId,
      source: 'watchtower',
    }, notif);
  }

  /**
   * Notify registered users about a new order.
   * SECURITY: Only notify users who have registered push tokens (not ALL relay users).
   * Uses #p tags from the event to identify targeted providers if available,
   * otherwise broadcasts to all registered users (limited by rate limiter).
   */
  async _notifyNewOrder(creatorPubkey, orderId, content, event) {
    // Dedup: skip if we already notified about this order
    const pushKey = `${orderId}:new_order:broadcast`;
    if (this._seenPushes.has(pushKey)) return;
    this._seenPushes.add(pushKey);

    const amount = content.amount || '?';
    const billType = content.billType || 'conta';
    const notif = {
      title: NOTIFICATION_MAP.new_order.title,
      body: `${billType} de R$ ${amount} disponível`,
    };

    // Get all registered pubkeys from pushService
    const tokenCount = pushService.getTokenCount();
    if (tokenCount === 0) return;

    // Check if event has #p tags (targeted providers)
    const pTags = (event.tags || [])
      .filter(t => t[0] === 'p' && t[1] && /^[0-9a-f]{64}$/.test(t[1]))
      .map(t => t[1]);

    let targetPubkeys;
    if (pTags.length > 0) {
      // Targeted: only notify specific providers mentioned in #p tags
      targetPubkeys = pTags.filter(pk => pk !== creatorPubkey);
    } else {
      // v544: Broadcast ONLY to users who enabled provider mode.
      // Users who never became providers will not receive 'Nova ordem' pushes.
      const providerPubkeys = pushService.getProviderPubkeys
        ? pushService.getProviderPubkeys()
        : [];
      targetPubkeys = providerPubkeys.filter(pk => pk !== creatorPubkey);
    }

    let sent = 0;
    for (const pubkey of targetPubkeys) {
      const ok = await this._sendPush(pubkey, {
        type: 'order_update',
        sender_pubkey: creatorPubkey,
        subtype: 'new_order',
        order_id: orderId,
        source: 'watchtower',
      }, notif);
      if (ok) sent++;
    }
    if (sent > 0) {
      console.log(`🗼 [Watchtower] New order ${orderId.substring(0, 8)}: notified ${sent} users`);
    }
  }

  /**
   * Wrapper around pushService.sendPush with stats tracking and rate limiting
   */
  async _sendPush(targetPubkey, data, notification) {
    // v540: Dedup persistente 24h por pubkey+orderId+subtype.
    // Protege contra flood quando backend reinicia ou Nostr republica eventos.
    const now = Date.now();
    const dedupKey = `${targetPubkey}:${data.order_id || 'no-order'}:${data.subtype || data.type}`;
    const lastSent = this._deliveredPushes.get(dedupKey);
    if (lastSent && (now - lastSent) < this._DELIVERED_TTL) {
      // Ja enviado nas ultimas 24h — skip
      return false;
    }

    // SECURITY: Per-pubkey rate limiting to prevent push notification spam
    const history = this._pushRateMap.get(targetPubkey) || [];
    const recent = history.filter(t => now - t < this._PUSH_RATE_WINDOW);
    if (recent.length >= this._PUSH_RATE_MAX) {
      // Rate limited — too many pushes to this pubkey
      return false;
    }
    recent.push(now);
    this._pushRateMap.set(targetPubkey, recent);

    // Periodic cleanup of rate map + delivered pushes (every 1000 pushes)
    if (this._stats.pushesSent % 1000 === 0 && this._pushRateMap.size > 100) {
      for (const [pk, times] of this._pushRateMap) {
        const valid = times.filter(t => now - t < this._PUSH_RATE_WINDOW);
        if (valid.length === 0) this._pushRateMap.delete(pk);
        else this._pushRateMap.set(pk, valid);
      }
      // v540: cleanup delivered pushes older than TTL
      for (const [k, ts] of this._deliveredPushes) {
        if (now - ts > this._DELIVERED_TTL) this._deliveredPushes.delete(k);
      }
    }

    try {
      const ok = await pushService.sendPush(targetPubkey, data, notification);
      if (ok) {
        this._stats.pushesSent++;
        this._deliveredPushes.set(dedupKey, now);
      } else {
        this._stats.pushesFailed++;
      }
      return ok;
    } catch (err) {
      this._stats.pushesFailed++;
      console.error(`❌ [Watchtower] Push failed for ${targetPubkey.substring(0, 8)}: ${err.message}`);
      return false;
    }
  }

  getStatus() {
    return {
      running: this._running,
      connectedRelays: Array.from(this._connections.keys()),
      totalRelays: RELAYS.length,
      seenEvents: this._seenEvents.size,
      stats: { ...this._stats },
    };
  }
}

// Singleton
const watchtower = new NostrWatchtowerService();
module.exports = watchtower;

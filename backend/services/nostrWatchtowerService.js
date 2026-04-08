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
    this._reconnectTimers = new Map();
    this._running = false;
    this._stats = { eventsProcessed: 0, pushesSent: 0, pushesFailed: 0, sigFailed: 0 };
    // SECURITY: Rate limit pushes per target pubkey (max 10 per 5 min)
    this._pushRateMap = new Map(); // pubkey → [timestamps]
    this._PUSH_RATE_WINDOW = 5 * 60 * 1000; // 5 minutes
    this._PUSH_RATE_MAX = 10; // max pushes per window per target
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

        // Subscribe to ALL bro-order tagged events from the last 2 hours
        // After initial catch-up, we get real-time events via the subscription
        const since = Math.floor(Date.now() / 1000) - 2 * 3600;

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
    const [type, , event] = msg;
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
          // New order created — notify relevant users
          console.log(`🗼 [Watchtower] New order ${shortId} from ${senderPubkey.substring(0, 8)}`);
          await this._notifyNewOrder(senderPubkey, orderId, content, event);
          break;
        }

        case 'bro_accept': {
          // Provider accepted — notify the order creator
          const userPubkey = content.userPubkey;
          if (isValidPubkey(userPubkey) && userPubkey !== senderPubkey) {
            console.log(`🗼 [Watchtower] Order ${shortId} accepted → notify ${userPubkey.substring(0, 8)}`);
            await this._sendOrderPush(userPubkey, senderPubkey, 'accepted', orderId);
          }
          break;
        }

        case 'bro_order_update': {
          // Status update — notify the OTHER party
          const status = content.status;
          const userPubkey = content.userPubkey;
          const providerId = content.providerId;

          if (!status) break;

          // Determine who to notify (the party that DIDN'T publish this event)
          let targetPubkey = null;
          if (senderPubkey === providerId && isValidPubkey(userPubkey)) {
            targetPubkey = userPubkey; // Provider published → notify user
          } else if (senderPubkey === userPubkey && isValidPubkey(providerId)) {
            targetPubkey = providerId; // User published → notify provider
          } else if (isValidPubkey(userPubkey) && userPubkey !== senderPubkey) {
            targetPubkey = userPubkey;
          } else if (isValidPubkey(providerId) && providerId !== senderPubkey) {
            targetPubkey = providerId;
          }

          if (targetPubkey) {
            console.log(`🗼 [Watchtower] Order ${shortId} → ${status} → notify ${targetPubkey.substring(0, 8)}`);
            await this._sendOrderPush(targetPubkey, senderPubkey, status, orderId);
          }
          break;
        }

        case 'bro_complete': {
          // Provider completed — notify the order creator
          const userPubkeyC = content.userPubkey;
          if (isValidPubkey(userPubkeyC) && userPubkeyC !== senderPubkey) {
            console.log(`🗼 [Watchtower] Order ${shortId} completed → notify ${userPubkeyC.substring(0, 8)}`);
            await this._sendOrderPush(userPubkeyC, senderPubkey, 'completed', orderId);
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
   * Send push notification for an order status change
   */
  async _sendOrderPush(targetPubkey, senderPubkey, status, orderId) {
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
      // Broadcast: notify all registered users (rate limiter prevents abuse)
      targetPubkeys = (pushService.getAllPubkeys ? pushService.getAllPubkeys() : [])
        .filter(pk => pk !== creatorPubkey);
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
    // SECURITY: Per-pubkey rate limiting to prevent push notification spam
    const now = Date.now();
    const history = this._pushRateMap.get(targetPubkey) || [];
    const recent = history.filter(t => now - t < this._PUSH_RATE_WINDOW);
    if (recent.length >= this._PUSH_RATE_MAX) {
      // Rate limited — too many pushes to this pubkey
      return false;
    }
    recent.push(now);
    this._pushRateMap.set(targetPubkey, recent);

    // Periodic cleanup of rate map (every 1000 pushes)
    if (this._stats.pushesSent % 1000 === 0 && this._pushRateMap.size > 100) {
      for (const [pk, times] of this._pushRateMap) {
        const valid = times.filter(t => now - t < this._PUSH_RATE_WINDOW);
        if (valid.length === 0) this._pushRateMap.delete(pk);
        else this._pushRateMap.set(pk, valid);
      }
    }

    try {
      const ok = await pushService.sendPush(targetPubkey, data, notification);
      if (ok) {
        this._stats.pushesSent++;
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

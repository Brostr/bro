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
    this._stats = { eventsProcessed: 0, pushesSent: 0, pushesFailed: 0 };
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

    this._stats.eventsProcessed++;

    const shortId = orderId.substring(0, 8);
    const senderPubkey = event.pubkey;

    try {
      switch (eventType) {
        case 'bro_order': {
          // New order created — notify all registered users EXCEPT the creator
          console.log(`🗼 [Watchtower] New order ${shortId} from ${senderPubkey.substring(0, 8)}`);
          await this._notifyNewOrder(senderPubkey, orderId, content);
          break;
        }

        case 'bro_accept': {
          // Provider accepted — notify the order creator
          const userPubkey = content.userPubkey;
          if (userPubkey && userPubkey !== senderPubkey) {
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
          if (senderPubkey === providerId && userPubkey) {
            targetPubkey = userPubkey; // Provider published → notify user
          } else if (senderPubkey === userPubkey && providerId) {
            targetPubkey = providerId; // User published → notify provider
          } else if (userPubkey && userPubkey !== senderPubkey) {
            targetPubkey = userPubkey;
          } else if (providerId && providerId !== senderPubkey) {
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
          const userPubkey = content.userPubkey;
          if (userPubkey && userPubkey !== senderPubkey) {
            console.log(`🗼 [Watchtower] Order ${shortId} completed → notify ${userPubkey.substring(0, 8)}`);
            await this._sendOrderPush(userPubkey, senderPubkey, 'completed', orderId);
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
   * Notify all registered users about a new order (except the creator)
   */
  async _notifyNewOrder(creatorPubkey, orderId, content) {
    const amount = content.amount || '?';
    const billType = content.billType || 'conta';
    const notif = {
      title: NOTIFICATION_MAP.new_order.title,
      body: `${billType} de R$ ${amount} disponível`,
    };

    // Get all registered pubkeys from pushService
    const tokenCount = pushService.getTokenCount();
    if (tokenCount === 0) return;

    // We need to iterate the token store — add a helper or use internal access
    const allPubkeys = pushService.getAllPubkeys ? pushService.getAllPubkeys() : [];
    let sent = 0;
    for (const pubkey of allPubkeys) {
      if (pubkey === creatorPubkey) continue; // Don't notify the creator
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
   * Wrapper around pushService.sendPush with stats tracking
   */
  async _sendPush(targetPubkey, data, notification) {
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

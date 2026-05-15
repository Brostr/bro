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
    // v568: Boot timestamp (sec). Events older than this won't trigger pushes.
    // Prevents the deploy-replay phantom-push bug: each deploy restarts the
    // service with empty _seenPushes, and historical events from the relay
    // (since=now-600s) would otherwise re-trigger push notifications that
    // were already delivered before the restart.
    this._bootTime = Math.floor(Date.now() / 1000);
    this._BOOT_GRACE_SEC = 30; // small grace for clock skew / in-flight events
    // v582: Backfill loop. The primary subscription is real-time only — if a
    // relay momentarily drops the event between WS frames, the watchtower
    // misses the push trigger forever. This happened in production for order
    // 33138e28 (accept never logged, provider stuck on "Obtendo dados de
    // pagamento"). Every BACKFILL_INTERVAL we send a transient REQ for
    // accept/update events in the last BACKFILL_WINDOW seconds. Dedup via
    // _seenEvents + _seenPushes prevents double-notification.
    this._backfillSubs = new Set(); // subIds awaiting EOSE so we can CLOSE
    this._backfillTimer = null;
    this._BACKFILL_INTERVAL_MS = 60_000;
    this._BACKFILL_WINDOW_SEC = 180;
    // v584: Tracking de pagamentos pendentes. Quando o provedor publica
    // bro_complete com providerInvoice, registramos aqui. Se em > 6h o
    // cliente não publicar status='completed'/'liquidated', re-pusha pra
    // forçar o app a sincronizar (em v584+ dispara autopay; em v564 só
    // notifica o cliente). Resolve casos como issue #6 (leandrogehlen).
    this._pendingInvoicePayments = new Map(); // orderId → { userPubkey, providerId, completedAt, attempts, lastAttemptAt }
    this._invoiceRetryTimer = null;
    this._INVOICE_RETRY_INTERVAL_MS = 60 * 60 * 1000;   // checa a cada 1h
    this._INVOICE_RETRY_FIRST_DELAY_MS = 6 * 60 * 60 * 1000;  // primeira tentativa só após 6h
    this._INVOICE_RETRY_MAX_ATTEMPTS = 24;              // ~24h de retries
    this._INVOICE_RETRY_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000; // desiste após 7d
  }

  start() {
    if (this._running) return;
    this._running = true;
    console.log('🗼 [Watchtower] Starting order event monitor on', RELAYS.length, 'relays');

    for (const relay of RELAYS) {
      this._connectToRelay(relay);
    }

    // v582: start backfill loop after initial connections settle
    this._backfillTimer = setInterval(() => this._backfillRecent(), this._BACKFILL_INTERVAL_MS);

    // v584: retry job pra pagamentos pendentes (bro_complete sem confirm do cliente)
    this._invoiceRetryTimer = setInterval(() => this._retryPendingInvoicePushes(), this._INVOICE_RETRY_INTERVAL_MS);
  }

  stop() {
    this._running = false;
    if (this._backfillTimer) {
      clearInterval(this._backfillTimer);
      this._backfillTimer = null;
    }
    if (this._invoiceRetryTimer) {
      clearInterval(this._invoiceRetryTimer);
      this._invoiceRetryTimer = null;
    }
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

  /**
   * v582: Periodic backfill. Sends a transient REQ for accept/update events
   * in the recent past to catch anything the live subscription dropped.
   * Dedup (_seenEvents + _seenPushes) means already-handled events are no-ops.
   * Subscription is closed automatically on EOSE.
   */
  _backfillRecent() {
    if (!this._running) return;
    const since = Math.floor(Date.now() / 1000) - this._BACKFILL_WINDOW_SEC;
    for (const [relayUrl, ws] of this._connections) {
      if (!ws || ws.readyState !== WebSocket.OPEN) continue;
      if (!this._eoseReceived.has(relayUrl)) continue; // wait until initial sub past EOSE
      const subId = `bro-wt-bf-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
      this._backfillSubs.add(subId);
      try {
        ws.send(JSON.stringify(['REQ', subId,
          {
            kinds: [KIND_ACCEPT, KIND_PAYMENT_PROOF, KIND_COMPLETE],
            '#t': ['bro-order'],
            since,
          },
          {
            kinds: [KIND_ACCEPT, KIND_PAYMENT_PROOF, KIND_COMPLETE],
            '#t': ['bro-update'],
            since,
          },
        ]));
      } catch (e) {
        this._backfillSubs.delete(subId);
      }
    }
    // Memory cap on outstanding backfill subs (in case relay never sends EOSE)
    if (this._backfillSubs.size > 50) {
      const arr = Array.from(this._backfillSubs);
      this._backfillSubs = new Set(arr.slice(-25));
    }
  }

  /**
   * v584: Job que re-pusha ordens cujo bro_complete foi visto mas o cliente
   * nunca publicou status=completed/liquidated. Resolve casos onde o evento
   * bro_complete (que carrega proof cifrado, ~80KB+) foi rejeitado por
   * tamanho em alguns relays e o cliente nunca viu o providerInvoice.
   * Em v584+ o push força sync → autopay automático.
   * Em v564 o push força sync → cliente vê a tela com ordem aguardando.
   */
  async _retryPendingInvoicePushes() {
    if (!this._running) return;
    if (this._pendingInvoicePayments.size === 0) return;
    const now = Date.now();
    const toDelete = [];
    for (const [orderId, info] of this._pendingInvoicePayments) {
      const age = now - info.completedAt;
      if (age > this._INVOICE_RETRY_MAX_AGE_MS) { toDelete.push(orderId); continue; }
      if (info.attempts >= this._INVOICE_RETRY_MAX_ATTEMPTS) { toDelete.push(orderId); continue; }
      if (age < this._INVOICE_RETRY_FIRST_DELAY_MS) continue;
      if (info.lastAttemptAt && now - info.lastAttemptAt < this._INVOICE_RETRY_INTERVAL_MS - 60_000) continue;

      try {
        const ok = await this._sendPush(info.userPubkey, {
          type: 'order_update',
          sender_pubkey: info.providerId,
          // Subtype único por tentativa pra burlar dedup 24h (cada retry é
          // independente; o intervalo é controlado pelo próprio job).
          subtype: `invoice_payment_due_${info.attempts + 1}`,
          order_id: orderId,
          source: 'watchtower_invoice_retry',
        }, {
          title: '💰 Pagamento pendente',
          body: 'Você tem um pagamento Bro pendente. Abra o app para confirmar.',
        });
        info.attempts += 1;
        info.lastAttemptAt = now;
        console.log(`🔁 [Watchtower] Retry invoice push ${info.shortId} attempt=${info.attempts} ok=${ok}`);
      } catch (err) {
        console.error(`❌ [Watchtower] Retry invoice push erro ${info.shortId}: ${err.message}`);
      }
    }
    for (const id of toDelete) this._pendingInvoicePayments.delete(id);
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
      // v582: backfill subscriptions are transient — CLOSE on EOSE
      if (this._backfillSubs.has(subId)) {
        this._backfillSubs.delete(subId);
        const ws = this._connections.get(relayUrl);
        if (ws && ws.readyState === WebSocket.OPEN) {
          try { ws.send(JSON.stringify(['CLOSE', subId])); } catch (_) { /* ignore */ }
        }
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

    // v568: Skip events published BEFORE this server boot. Belt-and-suspenders
    // along with the EOSE gate below — protects against deploy-replay phantom
    // pushes if a relay re-sends events post-EOSE on reconnect (some relays do).
    if (this._isHistoricalEvent(event)) return;

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
          //
          // SECURITY v577 (Phase 1 anti-replay): only trust the
          // self-declared `content.userPubkey` when it matches the event
          // signer. Otherwise, an attacker could publish a `bro_order`
          // event signed with their own key but carrying a victim's
          // pubkey in `content.userPubkey`, which would then route all
          // future accept/complete pushes for that orderId to the
          // attacker's chosen target. Falling back to `senderPubkey` is
          // safe because that is the cryptographically verified author.
          //
          // Also: do not OVERWRITE an existing cache entry with a
          // different pubkey. Real `bro_order` events are
          // parameterized-replaceable per `#d` tag and only the original
          // author can replace them, so a conflicting userPubkey for the
          // same orderId from a different author is necessarily
          // malicious.
          let orderUserPubkey;
          if (typeof content.userPubkey === 'string' && content.userPubkey === senderPubkey) {
            orderUserPubkey = content.userPubkey;
          } else if (content.userPubkey && content.userPubkey !== senderPubkey) {
            // Suspicious: signer is claiming someone else owns this order.
            // Fall back to the signer (verified) and log for audit.
            console.log(`⚠️ [Watchtower] order ${shortId} userPubkey mismatch: signer=${senderPubkey.substring(0,8)} claimed=${String(content.userPubkey).substring(0,8)} — using signer`);
            orderUserPubkey = senderPubkey;
          } else {
            orderUserPubkey = senderPubkey;
          }

          if (isValidPubkey(orderUserPubkey)) {
            const existing = this._orderUsers.get(orderId);
            if (!existing) {
              this._orderUsers.set(orderId, orderUserPubkey);
            } else if (existing !== orderUserPubkey) {
              // Different pubkey already cached for this orderId — keep
              // the original and log. This blocks late-arriving forged
              // events from hijacking routing for an existing order.
              console.log(`⚠️ [Watchtower] order ${shortId} cache conflict: kept=${existing.substring(0,8)} ignored=${orderUserPubkey.substring(0,8)}`);
            }
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
          // SECURITY v577: PREFER cache over content.userPubkey. The cache
          // entry came from a `bro_order` whose userPubkey was validated
          // against the signer. Trusting `content.userPubkey` from a
          // `bro_accept` event would let any signer redirect the
          // "accepted" push to an arbitrary pubkey by lying in their
          // event payload.
          const cachedUser = this._orderUsers.get(orderId);
          const userPubkeyA = (isValidPubkey(cachedUser) ? cachedUser : null)
            || (typeof content.userPubkey === 'string' && isValidPubkey(content.userPubkey) ? content.userPubkey : null);
          if (isValidPubkey(userPubkeyA) && userPubkeyA !== senderPubkey) {
            await this._sendOrderPush(userPubkeyA, senderPubkey, 'accepted', orderId, shortId);
            // v574: also send a SILENT data-only push to wake the buyer's
            // background isolate so it can encrypt the billCode via NIP-44
            // and publish kind 30080 — no need for the app to be open.
            // Failure here is non-fatal: plaintext billCode in kind 30078
            // remains the source of truth for the provider, so the order
            // never blocks. NIP-44 path is privacy-extra, not load-bearing.
            await this._sendBillcodeRelayPush(userPubkeyA, senderPubkey, orderId, shortId);
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
          // SECURITY v577: prefer cache over content for userPubkey
          // routing (see bro_accept rationale).
          const cachedUserU = this._orderUsers.get(orderId);
          const userPubkey = (isValidPubkey(cachedUserU) ? cachedUserU : null)
            || (typeof content.userPubkey === 'string' && isValidPubkey(content.userPubkey) ? content.userPubkey : null);
          const providerId = content.providerId;

          if (!status) break;

          // Cache userPubkey if we see it for the first time
          // SECURITY v577: only seed cache from this event if the signer
          // IS that user (legitimate self-published status update).
          // Otherwise we'd let a malicious provider seed a forged user
          // pubkey for an order that never had a `bro_order` event seen.
          if (isValidPubkey(userPubkey) && !this._orderUsers.has(orderId) && userPubkey === senderPubkey) {
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

          // v584: limpa tracking de invoice pendente quando ordem termina
          // (de qualquer maneira: pagamento, liquidação, cancel ou disputa).
          if (status === 'completed' || status === 'liquidated' || status === 'cancelled' || status === 'disputed') {
            if (this._pendingInvoicePayments.delete(orderId)) {
              console.log(`✅ [Watchtower] Limpando pending invoice ${shortId} (status=${status})`);
            }
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

          // v584: rastreia ordem pra eventual retry caso cliente nunca confirme.
          // Só se o provedor incluiu providerInvoice (sem invoice não há nada a pagar).
          const hasInvoice = typeof content.providerInvoice === 'string' && content.providerInvoice.length > 50;
          if (hasInvoice && isValidPubkey(userPubkeyC) && userPubkeyC !== senderPubkey && !this._isHistoricalEvent(event)) {
            if (!this._pendingInvoicePayments.has(orderId)) {
              this._pendingInvoicePayments.set(orderId, {
                userPubkey: userPubkeyC,
                providerId: senderPubkey,
                completedAt: Date.now(),
                attempts: 0,
                lastAttemptAt: 0,
                shortId,
              });
              console.log(`🧾 [Watchtower] Tracking invoice payment pendente: ${shortId} → ${userPubkeyC.substring(0,8)}`);
              // cap memória — 1000 entradas
              if (this._pendingInvoicePayments.size > 1000) {
                const first = this._pendingInvoicePayments.keys().next().value;
                if (first) this._pendingInvoicePayments.delete(first);
              }
            }
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
   * v568: True if this event was published before the server booted. Such
   * events should still update internal caches but MUST NOT trigger pushes:
   * the previous instance already pushed them, and re-pushing causes phantom
   * notifications after every deploy.
   */
  _isHistoricalEvent(event) {
    if (!event || typeof event.created_at !== 'number') return false;
    return event.created_at < (this._bootTime - this._BOOT_GRACE_SEC);
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
   * v574: Send a SILENT data-only push to wake the order creator's background
   * isolate so it can publish the NIP-44-encrypted billCode for the accepter.
   * Separate from the visible "Bro encontrado!" notification because iOS only
   * grants background execution time when the push is data-only with
   * apns-push-type=background + content-available=1.
   *
   * Idempotent: deduped per (target, orderId, accepter) inside _sendPush.
   * Non-fatal: if it fails, plaintext billCode in kind 30078 still works.
   */
  async _sendBillcodeRelayPush(targetPubkey, accepterPubkey, orderId, shortId) {
    if (targetPubkey === accepterPubkey) return false;
    return this._sendPush(targetPubkey, {
      type: 'order_update',
      sender_pubkey: accepterPubkey,
      subtype: 'accept_relay',
      order_id: orderId,
      accepter_pubkey: accepterPubkey,
      source: 'watchtower',
    }, null);  // null = silent / data-only / wakes background isolate
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
      // v588: + filter by provider's declared payment methods (billType).
      const providerPubkeys = pushService.getProviderPubkeys
        ? pushService.getProviderPubkeys(billType)
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

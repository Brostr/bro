/**
 * Push notification routes
 * 
 * POST /push/register-token — Register FCM token (requires NIP-98 auth)
 * POST /push/notify         — Send push to another user (requires NIP-98 auth)
 * POST /push/broadcast       — Admin: send notification to ALL registered users (requires NIP-98 + ADMIN_PUBKEY)
 * GET  /push/status          — Push service status (public)
 */

const express = require('express');
const rateLimit = require('express-rate-limit');
const router = express.Router();
const pushService = require('../services/pushService');

// Rate limiting: 10 notifications per minute per IP
const notifyLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Too many push requests. Try again in 1 minute.' },
});

// Rate limiting: 5 token registrations per minute per pubkey
const registerLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 5,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.verifiedPubkey || req.ip,
  validate: false,
  message: { error: 'Too many registration requests.' },
});

// Allowed push types and subtypes
const ALLOWED_TYPES = new Set(['order_update', 'brix_invoice_request']);
const ALLOWED_SUBTYPES = new Set(['accepted', 'billcode_encrypted', 'payment_received', 'completed', 'disputed', 'cancelled']);

/**
 * POST /push/register-token
 * Body: { fcm_token: string }
 * Auth: NIP-98 (req.verifiedPubkey)
 */
router.post('/register-token', registerLimiter, (req, res) => {
  const pubkey = req.verifiedPubkey;
  const { fcm_token } = req.body;
  
  if (!fcm_token || typeof fcm_token !== 'string' || fcm_token.length < 100 || fcm_token.length > 4096) {
    return res.status(400).json({ error: 'Invalid fcm_token' });
  }
  // SECURITY v448: Validate FCM token contains only base64url-safe chars + colons/dashes
  if (!/^[A-Za-z0-9_:.-]{100,4096}$/.test(fcm_token)) {
    return res.status(400).json({ error: 'Invalid fcm_token format' });
  }
  
  const ok = pushService.registerToken(pubkey, fcm_token);
  res.json({ ok, push_enabled: pushService.isEnabled() });
});

/**
 * POST /push/notify
 * Body: { target_pubkey: string, type: string, subtype: string, order_id?: string }
 * Auth: NIP-98 (req.verifiedPubkey)
 * 
 * Sends a data-only push notification to the target user.
 * The sender's pubkey is included so the recipient knows who triggered it.
 */
router.post('/notify', notifyLimiter, async (req, res) => {
  const senderPubkey = req.verifiedPubkey;
  const { target_pubkey, type, subtype, order_id } = req.body;
  
  // Validate target_pubkey (64-char hex)
  if (!target_pubkey || typeof target_pubkey !== 'string' || !/^[0-9a-f]{64}$/.test(target_pubkey)) {
    return res.status(400).json({ error: 'Invalid target_pubkey' });
  }
  
  // Whitelist allowed types
  if (!type || typeof type !== 'string' || !ALLOWED_TYPES.has(type)) {
    return res.status(400).json({ error: 'Invalid type' });
  }
  
  // Whitelist allowed subtypes
  if (subtype && !ALLOWED_SUBTYPES.has(subtype)) {
    return res.status(400).json({ error: 'Invalid subtype' });
  }
  
  // Validate order_id format (UUID-like, max 64 chars, alphanumeric + hyphens)
  if (order_id && (typeof order_id !== 'string' || order_id.length > 64 || !/^[a-zA-Z0-9_-]+$/.test(order_id))) {
    return res.status(400).json({ error: 'Invalid order_id' });
  }
  
  // Prevent self-notify
  if (target_pubkey === senderPubkey) {
    return res.json({ ok: false, reason: 'self_notify' });
  }
  
  // Build data payload (all values must be strings for FCM)
  const data = {
    type: String(type),
    sender_pubkey: senderPubkey,
  };
  
  if (subtype) data.subtype = String(subtype);
  if (order_id) data.order_id = String(order_id);

  // Build notification for order_update → guaranteed background delivery
  // BRIX invoice requests stay data-only (need silent background processing)
  let notification = null;
  if (type === 'order_update') {
    const notifMap = {
      accepted:           { title: '🤝 Ordem aceita!',        body: 'Um Bro aceitou sua ordem' },
      billcode_encrypted: { title: '🔐 Código PIX recebido',  body: 'Código de pagamento disponível' },
      payment_received:   { title: '📸 Comprovante recebido!', body: 'Verifique o comprovante e confirme' },
      completed:          { title: '✅ Ordem concluída!',      body: 'Troca finalizada com sucesso' },
      disputed:           { title: '⚠️ Disputa aberta',       body: 'Uma disputa foi aberta na sua ordem' },
      cancelled:          { title: '❌ Ordem cancelada',       body: 'Uma ordem foi cancelada' },
    };
    notification = notifMap[subtype] || { title: '📋 Atualização de ordem', body: 'Abra o app para ver as novidades' };
  }

  console.log(`[PUSH] /notify from=${senderPubkey.substring(0, 16)}... to=${target_pubkey.substring(0, 16)}... type=${type} subtype=${subtype || 'none'}`);

  const sent = await pushService.sendPush(target_pubkey, data, notification);
  
  console.log(`[PUSH] /notify result: sent=${sent} type=${type} subtype=${subtype || 'none'}`);
  res.json({ ok: sent });
});

/**
 * GET /push/status
 * Returns push service status (no auth required)
 */
router.get('/status', (req, res) => {
  res.json({
    enabled: pushService.isEnabled(),
    tokens_registered: pushService.getTokenCount(),
  });
});

// Admin pubkey from env
const ADMIN_PUBKEY = process.env.ADMIN_PUBKEY || '';

// Rate limiting: 1 broadcast per 5 minutes
const broadcastLimiter = rateLimit({
  windowMs: 5 * 60 * 1000,
  max: 1,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Broadcast rate limited. Try again in 5 minutes.' },
});

/**
 * POST /push/broadcast
 * Body: { title: string, body: string }
 * Auth: NIP-98 + ADMIN_PUBKEY required
 * 
 * Sends a visible notification to ALL registered users.
 * Throttled: 1 push/second per recipient to respect FCM quota.
 */
router.post('/broadcast', broadcastLimiter, async (req, res) => {
  // Verify admin
  if (!ADMIN_PUBKEY || !/^[0-9a-f]{64}$/.test(ADMIN_PUBKEY)) {
    return res.status(503).json({ error: 'ADMIN_PUBKEY not configured' });
  }
  if (req.verifiedPubkey !== ADMIN_PUBKEY) {
    return res.status(403).json({ error: 'Admin access required' });
  }

  const { title, body } = req.body;

  if (!title || typeof title !== 'string' || title.length < 1 || title.length > 200) {
    return res.status(400).json({ error: 'title is required (1-200 chars)' });
  }
  if (!body || typeof body !== 'string' || body.length < 1 || body.length > 500) {
    return res.status(400).json({ error: 'body is required (1-500 chars)' });
  }

  const allPubkeys = pushService.getAllPubkeys();
  if (allPubkeys.length === 0) {
    return res.json({ success: true, sent: 0, failed: 0, total: 0, message: 'No registered users' });
  }

  console.log(`[PUSH] Broadcasting to ${allPubkeys.length} users: "${title}"`);

  // Send async — respond immediately, process in background
  res.json({
    success: true,
    total: allPubkeys.length,
    message: `Broadcasting to ${allPubkeys.length} users. Check server logs for progress.`,
  });

  // Process sends with 1s delay between each to respect FCM quota
  let sent = 0;
  let failed = 0;

  for (const pubkey of allPubkeys) {
    try {
      const ok = await pushService.sendPush(
        pubkey,
        { type: 'app_update', broadcast: 'true' },
        { title, body }
      );
      if (ok) sent++;
      else failed++;
    } catch (e) {
      failed++;
    }

    // Throttle: 1 push per second
    await new Promise(r => setTimeout(r, 1000));
  }

  console.log(`[PUSH] Broadcast complete: ${sent} sent, ${failed} failed, ${allPubkeys.length} total`);
});

module.exports = router;

/**
 * v688: Canal redundante de entrega do billCode (backend + FCM).
 *
 * Motivo (caso real 72d248d8, 31/out): o billCode NIP-44 só viajava pelos
 * relays Nostr. Se o app do comprador acorda mas os relays falham no aparelho
 * dele, o provedor nunca recebe o código. Agora o comprador TAMBÉM posta o
 * blob cifrado aqui; o backend acorda o provedor via FCM silencioso e o
 * provedor busca o blob por GET.
 *
 * PRIVACIDADE: o blob é NIP-44 comprador→provedor — o servidor só transporta
 * ciphertext, igual a um relay público. Nada de plaintext por aqui.
 *
 * Anti-abuso:
 * - blob limitado a 100KB (imagem não passa aqui, só código)
 * - comprador e provedor validados contra o Watchtower antes de gravar ou ler
 * - 1 entrada por orderId (última vence), TTL 48h, máx 500 entradas.
 */
const express = require('express');
const fs = require('fs');
const path = require('path');
const { requireAuth } = require('../middleware/verifyNip98Auth');

const FALLBACK_FILE = process.env.NODE_ENV === 'production'
  ? '/data/billcode_fallback.json'
  : path.join(__dirname, '..', 'data', 'billcode_fallback.json');

const TTL_MS = 48 * 60 * 60 * 1000;
const MAX_ENTRIES = 500;
const MAX_BLOB = 100 * 1024;

const HEX64 = /^[0-9a-f]{64}$/;

const ORDER_ID = /^[a-zA-Z0-9-]{8,64}$/;

function loadStore() {
  try {
    if (!fs.existsSync(FALLBACK_FILE)) return {};
    const data = JSON.parse(fs.readFileSync(FALLBACK_FILE, 'utf8'));
    return data && typeof data === 'object' ? data : {};
  } catch (_) {
    return {};
  }
}

let saveTimer = null;
function scheduleSave(store) {
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    try {
      const dir = path.dirname(FALLBACK_FILE);
      if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
      const now = Date.now();
      const pruned = Object.fromEntries(
        Object.entries(store)
          .filter(([, v]) => v && typeof v.ts === 'number' && now - v.ts <= TTL_MS)
          .sort((a, b) => b[1].ts - a[1].ts)
          .slice(0, MAX_ENTRIES)
      );
      fs.writeFileSync(FALLBACK_FILE, JSON.stringify(pruned), { encoding: 'utf8', mode: 0o600 });
    } catch (e) {
      console.error(`[BillcodeFallback] persist falhou: ${e.message}`);
    }
  }, 2000);
}

module.exports = function createBillcodeFallbackRouter(watchtower) {
  const router = express.Router();
  const store = loadStore();

  // Comprador publica o blob cifrado (NIP-44) destinado ao provedor
  router.post('/billcode-fallback', requireAuth, async (req, res) => {
    try {
      const { orderId, providerPubkey, senderPubkey, blob } = req.body || {};
      if (typeof orderId !== 'string' || !ORDER_ID.test(orderId)) {
        return res.status(400).json({ ok: false, error: 'orderId inválido' });
      }
      if (typeof providerPubkey !== 'string' || !HEX64.test(providerPubkey) ||
          typeof senderPubkey !== 'string' || !HEX64.test(senderPubkey)) {
        return res.status(400).json({ ok: false, error: 'pubkeys inválidas' });
      }
      if (typeof blob !== 'string' || blob.length < 32 || blob.length > MAX_BLOB) {
        return res.status(400).json({ ok: false, error: 'blob inválido' });
      }

      if (!req.verifiedPayload) {
        return res.status(401).json({ ok: false, error: 'payload NIP-98 obrigatório' });
      }
      if (req.verifiedPubkey !== senderPubkey ||
          watchtower.getBuyerForOrder(orderId) !== senderPubkey ||
          watchtower.getProviderForOrder(orderId) !== providerPubkey ||
          senderPubkey === providerPubkey) {
        return res.status(403).json({ ok: false, error: 'participantes não conferem com a ordem' });
      }

      store[orderId] = { providerPubkey, senderPubkey, blob, ts: Date.now() };
      scheduleSave(store);
      console.log(`📦 [BillcodeFallback] ${orderId.substring(0, 8)}: blob de ${senderPubkey.substring(0, 8)} → ${providerPubkey.substring(0, 8)} (${blob.length}ch)`);

      const pushed = await watchtower.pushBillcodeFallback(providerPubkey, senderPubkey, orderId);
      return res.json({ ok: true, pushed });
    } catch (e) {
      console.error(`[BillcodeFallback] POST erro: ${e.message}`);
      return res.status(500).json({ ok: false });
    }
  });

  router.get('/billcode-fallback/:orderId', requireAuth, (req, res) => {
    const { orderId } = req.params;
    const entry = ORDER_ID.test(orderId) && store[orderId];
    if (!entry || Date.now() - entry.ts > TTL_MS ||
        req.verifiedPubkey !== entry.providerPubkey ||
        watchtower.getProviderForOrder(orderId) !== entry.providerPubkey ||
        watchtower.getBuyerForOrder(orderId) !== entry.senderPubkey ||
        entry.senderPubkey === entry.providerPubkey) {
      return res.status(404).json({ ok: false, error: 'não encontrado' });
    }
    return res.json({
      ok: true,
      providerPubkey: entry.providerPubkey,
      senderPubkey: entry.senderPubkey,
      blob: entry.blob,
      ts: entry.ts,
    });
  });

  return router;
};

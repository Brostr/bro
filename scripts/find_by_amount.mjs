// Busca ordens kind 30078 nos relays com valor BRL aproximado.
// Uso: node find_by_amount.mjs 61.56
import WebSocket from 'ws';

const targetAmount = parseFloat(process.argv[2] || '61.56');
const tolerance = 1.0; // BRL — janela ampla
const sinceDays = parseInt(process.argv[3] || '10', 10);
const since = Math.floor(Date.now() / 1000) - sinceDays * 86400;

const relays = ['wss://relay.damus.io', 'wss://nos.lol', 'wss://relay.primal.net'];

function query(relay, filter, timeoutMs = 20000) {
  return new Promise((resolve) => {
    const ws = new WebSocket(relay);
    const results = [];
    const subId = 'q' + Math.random().toString(36).slice(2, 10);
    const timeout = setTimeout(() => { try { ws.close(); } catch {} resolve(results); }, timeoutMs);
    ws.on('open', () => { ws.send(JSON.stringify(['REQ', subId, filter])); });
    ws.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString());
        if (msg[0] === 'EVENT' && msg[1] === subId) results.push(msg[2]);
        else if (msg[0] === 'EOSE' && msg[1] === subId) {
          clearTimeout(timeout); try { ws.close(); } catch {} resolve(results);
        }
      } catch {}
    });
    ws.on('error', () => { clearTimeout(timeout); resolve(results); });
  });
}

console.log(`🔎 Buscando ordens k=30078 com valor ~${targetAmount} BRL (±${tolerance}) nos últimos ${sinceDays} dias…`);

const matches = new Map(); // orderId -> { ev, parsed, relays:[] }

for (const r of relays) {
  console.log(`\n→ ${r}`);
  const evs = await query(r, { kinds: [30078], '#t': ['bro-order'], since, limit: 5000 });
  console.log(`  ${evs.length} eventos k=30078`);
  for (const ev of evs) {
    let parsed = null;
    try { parsed = JSON.parse(ev.content); } catch {}
    const amountTag = ev.tags.find(t => t[0] === 'amount')?.[1];
    const amount = parseFloat(amountTag ?? parsed?.amount ?? parsed?.amountBrl ?? parsed?.value ?? 0);
    if (!Number.isFinite(amount) || Math.abs(amount - targetAmount) > tolerance) continue;
    const orderId = parsed?.orderId || ev.tags.find(t => t[0] === 'd')?.[1] || ev.id;
    if (!matches.has(orderId)) matches.set(orderId, { parsed: parsed || {}, ev, relays: [], amount });
    matches.get(orderId).relays.push(r);
  }
}

console.log(`\n✅ ${matches.size} ordens com valor compatível:\n`);
for (const [orderId, info] of matches) {
  const p = info.parsed;
  const created = new Date(info.ev.created_at * 1000).toISOString();
  console.log(`─ orderId: ${orderId}`);
  console.log(`  amount=${info.amount} BRL  createdAt=${created}`);
  console.log(`  userPubkey=${(p.userPubkey || info.ev.pubkey || '').slice(0, 16)}…`);
  console.log(`  providerId=${(p.providerId || '').slice(0, 16) || '(none yet)'}`);
  console.log(`  status (content)=${p.status || '?'}  status (tag)=${info.ev.tags.find(t=>t[0]==='status')?.[1] || '?'}`);
  console.log(`  relays=${info.relays.length}/3`);
  console.log('');
}

// Para cada match, fetch full timeline
for (const [orderId, info] of matches) {
  console.log(`\n########## TIMELINE ${orderId} ##########`);
  const all = [];
  for (const r of relays) {
    const evs = await query(r, { kinds: [30078, 30079, 30080, 30081], '#d': [orderId], limit: 100 });
    for (const ev of evs) all.push({ ...ev, _relay: r });
  }
  const seen = new Set();
  const unique = all.filter(e => { if (seen.has(e.id)) return false; seen.add(e.id); return true; });
  unique.sort((a, b) => a.created_at - b.created_at);
  for (const ev of unique) {
    let p = null;
    try { p = JSON.parse(ev.content); } catch {}
    console.log(
      new Date(ev.created_at * 1000).toISOString(),
      'k=' + ev.kind,
      'status=' + (p?.status || '?'),
      'from=' + ev.pubkey.slice(0, 8),
      p?.providerId ? 'prov=' + p.providerId.slice(0, 8) : '',
      p?.providerInvoice ? 'INV' : '',
      p?.proofImage || p?.paymentProof ? 'PROOF' : '',
    );
  }
}

process.exit(0);

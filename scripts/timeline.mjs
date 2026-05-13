// Timeline completa de 1 ordem em todos os relays do app
import WebSocket from 'ws';
const orderId = process.argv[2] || '92a2fdeb-40b0-4efb-9e79-b52ce518b6f7';
const relays = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://relay.nostr.band',
  'wss://relay.snort.social',
  'wss://nostr.wine',
];
function query(relay, filter, t = 15000) {
  return new Promise((resolve) => {
    const ws = new WebSocket(relay);
    const results = [];
    const sub = 'q' + Math.random().toString(36).slice(2, 10);
    const to = setTimeout(() => { try { ws.close(); } catch {} resolve(results); }, t);
    ws.on('open', () => ws.send(JSON.stringify(['REQ', sub, filter])));
    ws.on('message', (d) => {
      try {
        const m = JSON.parse(d.toString());
        if (m[0] === 'EVENT' && m[1] === sub) results.push(m[2]);
        else if (m[0] === 'EOSE' && m[1] === sub) { clearTimeout(to); try { ws.close(); } catch {} resolve(results); }
      } catch {}
    });
    ws.on('error', () => { clearTimeout(to); resolve(results); });
  });
}
console.log(`Looking up ${orderId} across ${relays.length} relays\n`);
const all = [];
for (const r of relays) {
  const evs = await query(r, { kinds: [30078, 30079, 30080, 30081], '#d': [orderId], limit: 100 });
  console.log(`  ${r}: ${evs.length} events`);
  for (const e of evs) all.push({ ...e, _relay: r });
}
const seen = new Set();
const uniq = all.filter(e => { if (seen.has(e.id)) return false; seen.add(e.id); return true; });
uniq.sort((a, b) => a.created_at - b.created_at);
console.log(`\n${uniq.length} unique events:\n`);
for (const ev of uniq) {
  let p = null;
  try { p = JSON.parse(ev.content); } catch {}
  const statusTag = ev.tags.find(t => t[0] === 'status')?.[1];
  console.log(
    new Date(ev.created_at*1000).toISOString(),
    'k=' + ev.kind,
    'type=' + (p?.type || '?'),
    'status=' + (p?.status || statusTag || '?'),
    'from=' + ev.pubkey.slice(0,8),
    p?.providerId ? 'prov=' + p.providerId.slice(0,8) : '',
    p?.providerInvoice ? '[INV]' : '',
    (p?.proofImage || p?.paymentProof) ? '[PROOF]' : '',
    'on=' + ev._relay.replace('wss://', ''),
  );
}
console.log('\n--- raw last event content (truncated) ---');
if (uniq.length) console.log(uniq[uniq.length-1].content.slice(0, 600));
process.exit(0);

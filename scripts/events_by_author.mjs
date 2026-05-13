// Busca ordens onde um pubkey é o PROVEDOR (aceitou)
import WebSocket from 'ws';
const targetPubkey = process.argv[2] || 'bd095004cf02e99ff2ab8836175f8b5fe3368295d427a45eb6ac96b55ae58a80';
const sinceDays = parseInt(process.argv[3] || '15', 10);
const since = Math.floor(Date.now() / 1000) - sinceDays * 86400;
const relays = [
  'wss://relay.damus.io', 'wss://nos.lol', 'wss://relay.primal.net',
  'wss://relay.nostr.band', 'wss://relay.snort.social', 'wss://nostr.wine',
];
function query(relay, filter, t = 20000) {
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

console.log(`🔎 Buscando eventos assinados por ${targetPubkey.slice(0,8)}… nos últimos ${sinceDays} dias\n`);

const all = [];
for (const r of relays) {
  // kinds 30079 = accept, 30080 = proof/update, 30081 = complete; só assinados por ele
  const evs = await query(r, { authors: [targetPubkey], kinds: [30078, 30079, 30080, 30081], since, limit: 500 });
  console.log(`  ${r}: ${evs.length} eventos assinados por ele`);
  for (const e of evs) all.push({ ...e, _relay: r });
}
const seen = new Set();
const uniq = all.filter(e => { if (seen.has(e.id)) return false; seen.add(e.id); return true; });
uniq.sort((a, b) => a.created_at - b.created_at);

console.log(`\n📅 ${uniq.length} eventos únicos assinados por ${targetPubkey.slice(0,8)}:\n`);
const orderIds = new Set();
for (const ev of uniq) {
  let p = null; try { p = JSON.parse(ev.content); } catch {}
  const dTag = ev.tags.find(t => t[0] === 'd')?.[1];
  if (dTag) orderIds.add(dTag);
  const statusTag = ev.tags.find(t => t[0] === 'status')?.[1];
  const amountTag = ev.tags.find(t => t[0] === 'amount')?.[1];
  console.log(
    new Date(ev.created_at*1000).toISOString(),
    'k=' + ev.kind,
    'type=' + (p?.type || '?'),
    'status=' + (p?.status || statusTag || '?'),
    'd=' + (dTag?.slice(0,8) || '?'),
    'amt=' + (amountTag || p?.amount || '?'),
    p?.providerId ? 'prov=' + p.providerId.slice(0,8) : '',
    p?.userPubkey ? 'user=' + p.userPubkey.slice(0,8) : '',
    p?.providerInvoice ? '[INV]' : '',
    (p?.proofImage || p?.paymentProof) ? '[PROOF]' : '',
  );
}

console.log(`\n🔗 ${orderIds.size} order IDs distintos onde ele aparece:\n${[...orderIds].join('\n')}`);
process.exit(0);

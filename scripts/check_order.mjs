import WebSocket from 'ws';

const shortId = process.argv[2] || 'f1202e8e';
const relays = ['wss://relay.damus.io', 'wss://nos.lol', 'wss://relay.primal.net'];

async function query(relay, filter) {
  return new Promise((resolve) => {
    const ws = new WebSocket(relay);
    const results = [];
    const subId = 'q' + Math.random().toString(36).slice(2, 10);
    const timeout = setTimeout(() => { try { ws.close(); } catch {} resolve(results); }, 10000);
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

const fullIds = new Set();
for (const r of relays) {
  const evs = await query(r, { kinds: [30078, 30079, 30080, 30081], '#t': ['bro-order'], limit: 500 });
  for (const ev of evs) {
    try {
      const c = JSON.parse(ev.content);
      if (c.orderId && c.orderId.startsWith(shortId)) fullIds.add(c.orderId);
    } catch {}
    const dTag = ev.tags.find(t => t[0] === 'd')?.[1];
    if (dTag && dTag.startsWith(shortId)) {
      const m = dTag.match(/^([0-9a-f-]{36})/);
      if (m) fullIds.add(m[1]);
    }
  }
}
console.log('Full IDs matching:', [...fullIds]);

for (const fullId of fullIds) {
  console.log(`\n########## ${fullId} ##########`);
  const allEvents = [];
  for (const r of relays) {
    const evs = await query(r, { kinds: [30078, 30079, 30080, 30081], '#d': [fullId], limit: 50 });
    const evs2 = await query(r, { kinds: [30078, 30079, 30080, 30081], '#r': [fullId], limit: 50 });
    for (const ev of [...evs, ...evs2]) allEvents.push({ ...ev, _relay: r });
  }
  const seen = new Set();
  const unique = allEvents.filter(e => { if (seen.has(e.id)) return false; seen.add(e.id); return true; });
  unique.sort((a, b) => a.created_at - b.created_at);
  for (const ev of unique) {
    let parsed = null;
    try { parsed = JSON.parse(ev.content); } catch {}
    const dTag = ev.tags.find(t => t[0] === 'd')?.[1];
    console.log(
      new Date(ev.created_at * 1000).toISOString(),
      'k=' + ev.kind,
      'type=' + (parsed?.type || '?'),
      'status=' + (parsed?.status || '?'),
      'from=' + ev.pubkey.slice(0, 8),
      'd=' + (dTag?.slice(0, 60) || '?'),
      parsed?.providerId ? 'prov=' + parsed.providerId.slice(0,8) : '',
      parsed?.providerInvoice ? 'INV' : '',
      parsed?.proofImage ? 'PROOF' : '',
      parsed?.paymentProof ? 'PP' : '',
      parsed?.userPubkey ? 'user=' + parsed.userPubkey.slice(0,8) : '',
    );
  }
}

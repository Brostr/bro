import WebSocket from 'ws';

const fullId = 'd82b4138-d907-4986-b3e2-7b708efdab7d';
const relays = ['wss://relay.damus.io', 'wss://nos.lol', 'wss://relay.primal.net'];

async function query(relay, filter) {
  return new Promise((resolve) => {
    const ws = new WebSocket(relay);
    const results = [];
    const subId = 'q' + Math.random().toString(36).slice(2, 10);
    const timeout = setTimeout(() => { try { ws.close(); } catch {} resolve(results); }, 12000);
    ws.on('open', () => {
      ws.send(JSON.stringify(['REQ', subId, filter]));
    });
    ws.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString());
        if (msg[0] === 'EVENT' && msg[1] === subId) {
          results.push(msg[2]);
        } else if (msg[0] === 'EOSE' && msg[1] === subId) {
          clearTimeout(timeout);
          try { ws.close(); } catch {}
          resolve(results);
        }
      } catch {}
    });
    ws.on('error', () => { clearTimeout(timeout); resolve(results); });
  });
}

// Try multiple queries
const queries = [
  { name: '#r tag', filter: { kinds: [30081], '#r': [fullId], limit: 50 } },
  { name: '#orderId tag', filter: { kinds: [30081], '#orderId': [fullId], limit: 50 } },
  { name: '#d tag complete', filter: { kinds: [30081], '#d': [`${fullId}_complete`], limit: 50 } },
  { name: '#d tag refresh', filter: { kinds: [30081], '#d': [`${fullId}_invoice_refresh`], limit: 50 } },
  { name: 'all 30081 by provider 4c020f93', filter: { kinds: [30081], authors: ['4c020f93e3240ba5215ce3f2d6b2b1e9ec57b64d0189b6411b8394d8a60c499d'], limit: 100 } },
];

for (const q of queries) {
  console.log(`\n======= ${q.name} =======`);
  for (const r of relays) {
    const evs = await query(r, q.filter);
    console.log(`--- ${r} (${evs.length}) ---`);
    for (const ev of evs.sort((a, b) => a.created_at - b.created_at)) {
      let parsed = null;
      try { parsed = JSON.parse(ev.content); } catch {}
      // Only show if relates to our order
      if (q.name.startsWith('all')) {
        if (parsed?.orderId !== fullId) continue;
      }
      const dTag = ev.tags.find(t => t[0] === 'd')?.[1];
      const rTag = ev.tags.find(t => t[0] === 'r')?.[1];
      console.log(
        new Date(ev.created_at * 1000).toISOString(),
        'k=' + ev.kind,
        'type=' + parsed?.type,
        'from=' + ev.pubkey.slice(0, 8),
        'orderId=' + parsed?.orderId?.slice(0, 8),
        'd=' + dTag?.slice(0, 50),
        'r=' + rTag?.slice(0, 8),
        parsed?.providerInvoice ? 'HAS_INV(' + parsed.providerInvoice.length + ')' : 'no_inv'
      );
    }
  }
}

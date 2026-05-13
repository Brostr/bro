// Dump sample do conteúdo dos eventos kind 30078 para entender estrutura
import WebSocket from 'ws';
const since = Math.floor(Date.now() / 1000) - 10 * 86400;
function query(relay, filter, timeoutMs = 20000) {
  return new Promise((resolve) => {
    const ws = new WebSocket(relay);
    const results = [];
    const subId = 'q' + Math.random().toString(36).slice(2, 10);
    const t = setTimeout(() => { try { ws.close(); } catch {} resolve(results); }, timeoutMs);
    ws.on('open', () => ws.send(JSON.stringify(['REQ', subId, filter])));
    ws.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString());
        if (msg[0] === 'EVENT' && msg[1] === subId) results.push(msg[2]);
        else if (msg[0] === 'EOSE' && msg[1] === subId) { clearTimeout(t); try { ws.close(); } catch {} resolve(results); }
      } catch {}
    });
    ws.on('error', () => { clearTimeout(t); resolve(results); });
  });
}
const evs = await query('wss://nos.lol', { kinds: [30078], '#t': ['bro-order'], since, limit: 20 });
console.log(`Got ${evs.length} bro-order events`);
for (const ev of evs.slice(0, 5)) {
  console.log('---', new Date(ev.created_at*1000).toISOString(), 'pk=', ev.pubkey.slice(0,8));
  console.log('content[0..200]=', ev.content.slice(0, 200));
  console.log('tags=', JSON.stringify(ev.tags.slice(0, 8)));
}
process.exit(0);

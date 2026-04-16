const WebSocket = require('ws');
const { decode } = require('C:/Users/produ/Documents/GitHub/bro_app/backend/node_modules/light-bolt11-decoder/bolt11.js');

const fullId = 'd82b4138-d907-4986-b3e2-7b708efdab7d';

function query(relay, filter) {
  return new Promise((resolve) => {
    const ws = new WebSocket(relay);
    const results = [];
    const subId = 'q' + Math.random().toString(36).slice(2, 10);
    const timeout = setTimeout(() => { try { ws.close(); } catch {} resolve(results); }, 10000);
    ws.on('open', () => ws.send(JSON.stringify(['REQ', subId, filter])));
    ws.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString());
        if (msg[0] === 'EVENT' && msg[1] === subId) results.push(msg[2]);
        else if (msg[0] === 'EOSE' && msg[1] === subId) { clearTimeout(timeout); try { ws.close(); } catch {} resolve(results); }
      } catch {}
    });
    ws.on('error', () => { clearTimeout(timeout); resolve(results); });
  });
}

(async () => {
  const evs = await query('wss://nos.lol', { kinds: [30081], '#d': [`${fullId}_invoice_refresh`], limit: 5 });
  for (const ev of evs) {
    const c = JSON.parse(ev.content);
    const inv = c.providerInvoice;
    console.log('Invoice length:', inv.length);
    console.log('Invoice:', inv);
    try {
      const dec = decode(inv);
      const now = Math.floor(Date.now() / 1000);
      const timestamp = dec.sections.find(s => s.name === 'timestamp')?.value;
      const expiry = dec.sections.find(s => s.name === 'expiry')?.value ?? 3600;
      const amount = dec.sections.find(s => s.name === 'amount')?.value;
      const paymentHash = dec.sections.find(s => s.name === 'payment_hash')?.value;
      const expiresAt = timestamp + expiry;
      console.log('\nDecoded:');
      console.log('  timestamp:', new Date(timestamp * 1000).toISOString());
      console.log('  expiry:', expiry, 'sec', `(${(expiry/86400).toFixed(1)} days)`);
      console.log('  expiresAt:', new Date(expiresAt * 1000).toISOString());
      console.log('  now:', new Date(now * 1000).toISOString());
      console.log('  expired?', now > expiresAt);
      console.log('  amount:', amount, 'msat =>', amount/1000, 'sats');
      console.log('  paymentHash:', paymentHash);
      console.log('  payee:', dec.payeeNodeKey);
    } catch (e) {
      console.error('Decode failed:', e.message, e.stack);
    }
  }
})();

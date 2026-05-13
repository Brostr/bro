import WebSocket from 'ws';
const orderId = '92a2fdeb-40b0-4efb-9e79-b52ce518b6f7';
const provider = 'e94caad7f412d179c5a173b0346ed91f56070b119180ada5a264b40e7bd60986';
function query(relay, filter, t=15000) {
  return new Promise((res)=>{
    const ws=new WebSocket(relay);const r=[];const s='q'+Math.random().toString(36).slice(2,8);
    const to=setTimeout(()=>{try{ws.close();}catch{}res(r);},t);
    ws.on('open',()=>ws.send(JSON.stringify(['REQ',s,filter])));
    ws.on('message',(d)=>{try{const m=JSON.parse(d.toString());if(m[0]==='EVENT'&&m[1]===s)r.push(m[2]);else if(m[0]==='EOSE'&&m[1]===s){clearTimeout(to);try{ws.close();}catch{}res(r);}}catch{}});
    ws.on('error',()=>{clearTimeout(to);res(r);});
  });
}
const relays = ['wss://relay.damus.io','wss://nos.lol'];
for (const r of relays) {
  const evs = await query(r, { authors:[provider], kinds:[30078,30079,30080,30081], '#r':[orderId], limit:50 });
  const evs2 = await query(r, { authors:[provider], kinds:[30079,30081], limit:200 });
  const all = [...evs, ...evs2.filter(e => {
    try { const p = JSON.parse(e.content); return p.orderId === orderId; } catch { return false; }
  })];
  const seen=new Set();
  for (const ev of all) {
    if (seen.has(ev.id)) continue; seen.add(ev.id);
    console.log(`\n=== ${r} / k=${ev.kind} / ${new Date(ev.created_at*1000).toISOString()}`);
    console.log('tags=', JSON.stringify(ev.tags));
    console.log('content=', ev.content.slice(0, 1500));
  }
}
process.exit(0);

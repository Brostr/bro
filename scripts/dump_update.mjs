import WebSocket from 'ws';
const orderId = '92a2fdeb-40b0-4efb-9e79-b52ce518b6f7';
const author = 'bd095004cf02e99ff2ab8836175f8b5fe3368295d427a45eb6ac96b55ae58a80';
function query(relay, filter, t=15000) {
  return new Promise((res) => {
    const ws = new WebSocket(relay);
    const r=[]; const s='q'+Math.random().toString(36).slice(2,8);
    const to=setTimeout(()=>{try{ws.close();}catch{}res(r);},t);
    ws.on('open',()=>ws.send(JSON.stringify(['REQ',s,filter])));
    ws.on('message',(d)=>{try{const m=JSON.parse(d.toString());if(m[0]==='EVENT'&&m[1]===s)r.push(m[2]);else if(m[0]==='EOSE'&&m[1]===s){clearTimeout(to);try{ws.close();}catch{}res(r);}}catch{}});
    ws.on('error',()=>{clearTimeout(to);res(r);});
  });
}
const evs = await query('wss://nos.lol', { authors:[author], kinds:[30080], limit:50 });
for (const ev of evs) {
  console.log('=== id=', ev.id.slice(0,16), ' at=', new Date(ev.created_at*1000).toISOString());
  console.log('tags=', JSON.stringify(ev.tags));
  console.log('content=', ev.content);
  console.log();
}
process.exit(0);

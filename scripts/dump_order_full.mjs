import WebSocket from 'ws';
function query(relay,filter,t=15000){return new Promise(res=>{const ws=new WebSocket(relay);const r=[];const s='q'+Math.random().toString(36).slice(2,8);const to=setTimeout(()=>{try{ws.close();}catch{}res(r);},t);ws.on('open',()=>ws.send(JSON.stringify(['REQ',s,filter])));ws.on('message',d=>{try{const m=JSON.parse(d.toString());if(m[0]==='EVENT'&&m[1]===s)r.push(m[2]);else if(m[0]==='EOSE'&&m[1]===s){clearTimeout(to);try{ws.close();}catch{}res(r);}}catch{}});ws.on('error',()=>{clearTimeout(to);res(r);});});}
const orderId='92a2fdeb-40b0-4efb-9e79-b52ce518b6f7';
const evs = await query('wss://relay.damus.io',{kinds:[30078],'#d':[orderId],limit:5},20000);
for (const e of evs) {
  console.log('AUTHOR pubkey:',e.pubkey);
  console.log('tags:',JSON.stringify(e.tags));
  try { const c=JSON.parse(e.content); console.log('content keys:',Object.keys(c)); console.log('content:',JSON.stringify(c,null,2)); } catch { console.log('content (raw):',e.content.slice(0,2000)); }
}
process.exit(0);

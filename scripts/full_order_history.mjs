import WebSocket from 'ws';
function query(relay,filter,t=15000){return new Promise(res=>{const ws=new WebSocket(relay);const r=[];const s='q'+Math.random().toString(36).slice(2,8);const to=setTimeout(()=>{try{ws.close();}catch{}res(r);},t);ws.on('open',()=>ws.send(JSON.stringify(['REQ',s,filter])));ws.on('message',d=>{try{const m=JSON.parse(d.toString());if(m[0]==='EVENT'&&m[1]===s)r.push(m[2]);else if(m[0]==='EOSE'&&m[1]===s){clearTimeout(to);try{ws.close();}catch{}res(r);}}catch{}});ws.on('error',()=>{clearTimeout(to);res(r);});});}
const orderId='92a2fdeb-40b0-4efb-9e79-b52ce518b6f7';
const relays=['wss://relay.damus.io','wss://nos.lol','wss://relay.primal.net','wss://relay.nostr.band','wss://relay.snort.social','wss://nostr.wine'];
const all=[];
for (const r of relays){
  // ALL events with this orderId in any tag
  const a=await query(r,{kinds:[30078,30079,30080,30081],'#orderId':[orderId],limit:50});
  const b=await query(r,{kinds:[30078,30079,30080,30081],'#d':[orderId,`${orderId}_accept`,`${orderId}_complete`,`${orderId}_${'bd095004'.padEnd(8,'_')}`],limit:50});
  for (const e of [...a,...b]) all.push({...e,_relay:r});
}
const seen=new Set();
const u=all.filter(e=>{if(seen.has(e.id))return false;seen.add(e.id);return true;});
u.sort((a,b)=>a.created_at-b.created_at);
console.log(`Total eventos únicos: ${u.length}\n`);
for (const e of u){
  console.log(`\n=== k=${e.kind} ${new Date(e.created_at*1000).toISOString()} author=${e.pubkey.slice(0,8)}`);
  console.log('tags:',JSON.stringify(e.tags));
  try {
    const c=JSON.parse(e.content);
    console.log('content:',JSON.stringify(c,null,2).slice(0,3000));
  } catch {
    console.log('content (raw):',e.content.slice(0,2000));
  }
}
process.exit(0);

import WebSocket from 'ws';
const provider = 'e94caad7f412d179c5a173b0346ed91f56070b119180ada5a264b40e7bd60986';
const since = Math.floor(Date.now()/1000) - 60*86400;
function query(relay,filter,t=20000){return new Promise(res=>{const ws=new WebSocket(relay);const r=[];const s='q'+Math.random().toString(36).slice(2,8);const to=setTimeout(()=>{try{ws.close();}catch{}res(r);},t);ws.on('open',()=>ws.send(JSON.stringify(['REQ',s,filter])));ws.on('message',d=>{try{const m=JSON.parse(d.toString());if(m[0]==='EVENT'&&m[1]===s)r.push(m[2]);else if(m[0]==='EOSE'&&m[1]===s){clearTimeout(to);try{ws.close();}catch{}res(r);}}catch{}});ws.on('error',()=>{clearTimeout(to);res(r);});});}
const relays=['wss://relay.damus.io','wss://nos.lol','wss://relay.primal.net'];
const all=[];
for (const r of relays) {
  const evs = await query(r, { authors:[provider], kinds:[30078,30079,30080,30081], since, limit:500 });
  console.log(`${r}: ${evs.length} eventos assinados por e94caad7`);
  for (const e of evs) all.push({...e,_relay:r});
}
const seen=new Set();
const u=all.filter(e=>{if(seen.has(e.id))return false;seen.add(e.id);return true;});
u.sort((a,b)=>a.created_at-b.created_at);
const orders=new Map();
for (const ev of u){
  let p=null;try{p=JSON.parse(ev.content);}catch{}
  if (!p?.orderId) continue;
  if (!orders.has(p.orderId)) orders.set(p.orderId,{events:[],user:p.userPubkey});
  orders.get(p.orderId).events.push({kind:ev.kind,type:p.type,at:new Date(ev.created_at*1000).toISOString(),status:p.status,hasProof:!!(p.proofImage||p.paymentProof||p.proofImage_nip44),from:ev.pubkey.slice(0,8)});
}
console.log(`\n📊 e94caad7 esteve envolvido em ${orders.size} orders nos últimos 60 dias\n`);
for (const [oid,info] of orders) {
  console.log(`─ ${oid}  user=${info.user?.slice(0,8)||'?'}…`);
  for (const e of info.events) {
    console.log(`    ${e.at}  k=${e.kind}  type=${e.type}  status=${e.status||'?'}  ${e.hasProof?'[PROOF]':''}`);
  }
  console.log('');
}
process.exit(0);

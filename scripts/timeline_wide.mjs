import WebSocket from 'ws';
const orderId = '92a2fdeb-40b0-4efb-9e79-b52ce518b6f7';
const relays = [
  'wss://relay.damus.io','wss://nos.lol','wss://relay.primal.net',
  'wss://relay.nostr.band','wss://relay.snort.social','wss://nostr.wine',
];
function query(relay, filter, t=15000) {
  return new Promise((res)=>{
    const ws=new WebSocket(relay);const r=[];const s='q'+Math.random().toString(36).slice(2,8);
    const to=setTimeout(()=>{try{ws.close();}catch{}res(r);},t);
    ws.on('open',()=>ws.send(JSON.stringify(['REQ',s,filter])));
    ws.on('message',(d)=>{try{const m=JSON.parse(d.toString());if(m[0]==='EVENT'&&m[1]===s)r.push(m[2]);else if(m[0]==='EOSE'&&m[1]===s){clearTimeout(to);try{ws.close();}catch{}res(r);}}catch{}});
    ws.on('error',()=>{clearTimeout(to);res(r);});
  });
}
const dTags = [
  orderId,
  `${orderId}_accept`,
  `${orderId}_complete`,
];
const all=[];
for (const r of relays) {
  for (const d of dTags) {
    const evs = await query(r, { '#d':[d], limit:50 });
    for (const e of evs) all.push({...e,_relay:r,_d:d});
  }
  // Also any event referencing via 'r' tag
  const evsR = await query(r, { '#r':[orderId], limit:50 });
  for (const e of evsR) all.push({...e,_relay:r,_d:'r-tag'});
  // Also #orderId tag
  const evsO = await query(r, { '#orderId':[orderId], limit:50 });
  for (const e of evsO) all.push({...e,_relay:r,_d:'orderId-tag'});
}
const seen=new Set();
const u=all.filter(e=>{if(seen.has(e.id))return false;seen.add(e.id);return true;});
u.sort((a,b)=>a.created_at-b.created_at);
console.log(`Found ${u.length} unique events touching this order:\n`);
for (const ev of u) {
  let p=null; try{p=JSON.parse(ev.content);}catch{}
  console.log(
    new Date(ev.created_at*1000).toISOString(),
    'k='+ev.kind,
    'type='+(p?.type||'?'),
    'status='+(p?.status||ev.tags.find(t=>t[0]==='status')?.[1]||'?'),
    'from='+ev.pubkey.slice(0,8),
    p?.providerId?'prov='+p.providerId.slice(0,8):'',
    p?.userPubkey?'user='+p.userPubkey.slice(0,8):'',
    p?.providerInvoice?'[INV]':'',
    (p?.proofImage||p?.paymentProof)?'[PROOF]':'',
    'matched=' + ev._d,
    'on=' + ev._relay.replace('wss://',''),
  );
}
process.exit(0);

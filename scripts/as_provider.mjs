// Busca ordens onde bd095004 aparece como providerId (tag 'p' ou no content)
import WebSocket from 'ws';
const targetPubkey = 'bd095004cf02e99ff2ab8836175f8b5fe3368295d427a45eb6ac96b55ae58a80';
const sinceDays = parseInt(process.argv[2] || '15', 10);
const since = Math.floor(Date.now() / 1000) - sinceDays * 86400;
const relays = ['wss://relay.damus.io','wss://nos.lol','wss://relay.primal.net','wss://relay.nostr.band','wss://relay.snort.social','wss://nostr.wine'];
function query(relay, filter, t=20000) {
  return new Promise((res)=>{
    const ws=new WebSocket(relay);const r=[];const s='q'+Math.random().toString(36).slice(2,8);
    const to=setTimeout(()=>{try{ws.close();}catch{}res(r);},t);
    ws.on('open',()=>ws.send(JSON.stringify(['REQ',s,filter])));
    ws.on('message',(d)=>{try{const m=JSON.parse(d.toString());if(m[0]==='EVENT'&&m[1]===s)r.push(m[2]);else if(m[0]==='EOSE'&&m[1]===s){clearTimeout(to);try{ws.close();}catch{}res(r);}}catch{}});
    ws.on('error',()=>{clearTimeout(to);res(r);});
  });
}
console.log(`🔎 Busca: eventos com #p=${targetPubkey.slice(0,8)}… OU content.providerId match\n`);
const all=[];
for (const r of relays) {
  // p-tag (most accept/complete events tag the provider)
  const evs1 = await query(r, { '#p':[targetPubkey], kinds:[30078,30079,30080,30081], since, limit:500 });
  // also content scan: fetch broad and filter
  const evs2 = await query(r, { kinds:[30079,30081], '#t':['bro-order'], since, limit:1000 });
  console.log(`  ${r}: p-tag=${evs1.length}, broad k30079+30081=${evs2.length}`);
  for (const e of evs1) all.push({...e,_relay:r,_via:'p-tag'});
  for (const e of evs2) {
    try {
      const p = JSON.parse(e.content);
      if (p.providerId === targetPubkey) all.push({...e,_relay:r,_via:'content.providerId'});
    } catch {}
  }
}
const seen=new Set();
const u=all.filter(e=>{if(seen.has(e.id))return false;seen.add(e.id);return true;});
u.sort((a,b)=>a.created_at-b.created_at);
console.log(`\n${u.length} eventos únicos onde ${targetPubkey.slice(0,8)} aparece como provider:\n`);
for (const ev of u) {
  let p=null;try{p=JSON.parse(ev.content);}catch{}
  const dTag=ev.tags.find(t=>t[0]==='d')?.[1];
  console.log(
    new Date(ev.created_at*1000).toISOString(),
    'k='+ev.kind,
    'type='+(p?.type||'?'),
    'status='+(p?.status||'?'),
    'from='+ev.pubkey.slice(0,8),
    'd='+(dTag?.slice(0,12)||'?'),
    'user='+(p?.userPubkey?.slice(0,8)||'?'),
    'via='+ev._via,
  );
}
process.exit(0);

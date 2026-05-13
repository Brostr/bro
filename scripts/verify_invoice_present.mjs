import WebSocket from 'ws';
import fs from 'fs';
function query(relay,filter,t=20000){return new Promise(res=>{const ws=new WebSocket(relay);const r=[];const s='q'+Math.random().toString(36).slice(2,8);const to=setTimeout(()=>{try{ws.close();}catch{}res(r);},t);ws.on('open',()=>ws.send(JSON.stringify(['REQ',s,filter])));ws.on('message',d=>{try{const m=JSON.parse(d.toString());if(m[0]==='EVENT'&&m[1]===s)r.push(m[2]);else if(m[0]==='EOSE'&&m[1]===s){clearTimeout(to);try{ws.close();}catch{}res(r);}}catch{}});ws.on('error',()=>{clearTimeout(to);res(r);});});}
const orderId='92a2fdeb-40b0-4efb-9e79-b52ce518b6f7';
const relays=['wss://relay.damus.io','wss://nos.lol','wss://relay.primal.net','wss://relay.nostr.band','wss://relay.snort.social','wss://nostr.wine'];
const out={};
for (const r of relays){
  const a=await query(r,{kinds:[30081],'#d':[`${orderId}_complete`],limit:5});
  const b=await query(r,{kinds:[30080],'#orderId':[orderId],limit:50});
  out[r]={complete:a,updates:b};
}
fs.writeFileSync('c:\\temp\\full_complete_raw.json',JSON.stringify(out,null,2));
let foundInvoice=false;
for (const [r,d] of Object.entries(out)){
  for (const ev of d.complete){
    try {
      const c=JSON.parse(ev.content);
      console.log(`[${r}] complete keys:`,Object.keys(c).join(', '));
      console.log(`     providerInvoice present? ${c.providerInvoice?'YES len='+c.providerInvoice.length:'NO'}`);
      console.log(`     content length: ${ev.content.length}`);
      if (c.providerInvoice) foundInvoice=true;
    } catch(e) { console.log('parse err',e.message); }
  }
  for (const ev of d.updates){
    try {
      const c=JSON.parse(ev.content);
      if (c.providerInvoice || c.type==='bro_provider_invoice' || c.type==='bro_payment_proof' || c.invoice) {
        console.log(`[${r}] update type=${c.type} has invoice? ${!!(c.providerInvoice||c.invoice)}`);
        if (c.providerInvoice||c.invoice) foundInvoice=true;
      }
    } catch{}
  }
}
console.log('\n>>> providerInvoice found anywhere?',foundInvoice);
process.exit(0);

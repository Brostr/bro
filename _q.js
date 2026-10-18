const db=require("/app/server/node_modules/better-sqlite3")("/data/brix.db",{readonly:true});
const pk="345cbfb6c2f9be6bcca057ef1edcbb6d5934330f10d87abb4171f5fd84c8f51f";
const u=db.prepare("SELECT id,username,verified,created_at,last_seen FROM brix_users WHERE nostr_pubkey = ?").all(pk);
console.log("conta BRIX dele:", JSON.stringify(u));
if(u.length){
  const uid=u[0].id;
  console.log("pendings dele:", JSON.stringify(db.prepare("SELECT id,amount_sats,status,created_at FROM brix_pending_payments WHERE user_id = ? ORDER BY created_at DESC LIMIT 10").all(uid)));
  console.log("invoice_requests dele:", JSON.stringify(db.prepare("SELECT id,amount_sats,status,created_at FROM brix_invoice_requests WHERE user_id = ? ORDER BY created_at DESC LIMIT 10").all(uid)));
}
console.log("== atividade BRIX 17/10 20:00 a 18/10 06:00 UTC ==");
for(const r of db.prepare("SELECT id,user_id,amount_sats,status,created_at FROM brix_pending_payments WHERE created_at BETWEEN ? AND ?").all("2026-10-17 20:00","2026-10-18 06:00")) console.log(JSON.stringify(r));
for(const r of db.prepare("SELECT id,user_id,amount_sats,status,created_at FROM brix_invoice_requests WHERE created_at BETWEEN ? AND ?").all("2026-10-17 20:00","2026-10-18 06:00")) console.log(JSON.stringify(r));
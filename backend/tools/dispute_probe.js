#!/usr/bin/env node
/**
 * dispute_probe.js — Ferramenta de mediação de disputas do Bro.
 *
 * Reconstrói a linha do tempo completa de uma ordem a partir dos relays Nostr,
 * consultando todos os eventos do protocolo Bro (kinds 30078/30079/30080/30081
 * e kind 1 de disputa/evidência/mediação) e ordenando por data.
 *
 * Serve para o mediador verificar, SEM depender do app:
 *   - Quem criou a ordem e quem aceitou (kind 30079) — e se houve ACEITE EM
 *     DUPLICIDADE (mais de um provedor).
 *   - Onde a ordem travou (último status alcançado).
 *   - Se o comprovante foi enviado (kind 30081 = sim, imagem cifrada p/ usuário).
 *   - Quem abriu a disputa e quando (kind 1 #t=bro-disputa) vs. o comprovante.
 *   - Quantas evidências cada parte mandou (kind 1 #t=bro-disputa-evidencia,
 *     cifradas para ADMIN_PUBKEY — o conteúdo só é legível logado como admin no app).
 *
 * NÃO descriptografa evidências e NÃO publica nada nos relays (somente leitura).
 *
 * Uso:
 *   node backend/tools/dispute_probe.js <orderId> [orderId2 ...]
 *   npm --prefix backend run dispute -- <orderId> [orderId2 ...]
 *
 * Requer: ws (já em backend/dependencies).
 */
const WebSocket = require('ws');

const RELAYS = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://relay.nostr.band',
];

const COLLECT_MS = 7000; // janela de coleta por relay

const ORDERS = process.argv.slice(2);
if (ORDERS.length === 0) {
  console.error('uso: node backend/tools/dispute_probe.js <orderId> [orderId2 ...]');
  process.exit(1);
}

function filtersFor(orderId) {
  return [
    { kinds: [30078], '#d': [orderId] },
    { kinds: [30079], '#d': [`${orderId}_accept`] },
    { kinds: [30081], '#d': [`${orderId}_complete`] },
    { kinds: [30080], '#r': [orderId] },
    { kinds: [30080], '#d': [`${orderId}_resolution`, `${orderId}_admin_reimbursement`, `${orderId}_invoice_refresh`] },
    { kinds: [1], '#r': [orderId] },
    { kinds: [1], '#d': [orderId] },
  ];
}

const events = new Map(); // id -> {event, relays:Set}

function collectFromRelay(url) {
  return new Promise((resolve) => {
    let ws;
    let done = false;
    const finish = () => { if (!done) { done = true; try { ws.close(); } catch (_) {} resolve(); } };
    try { ws = new WebSocket(url); } catch (e) { return resolve(); }
    const subs = [];
    ORDERS.forEach((oid, oi) => filtersFor(oid).forEach((f, fi) => subs.push([`s${oi}_${fi}`, f])));
    const timer = setTimeout(finish, COLLECT_MS);
    ws.on('open', () => {
      subs.forEach(([id, f]) => ws.send(JSON.stringify(['REQ', id, f])));
    });
    ws.on('message', (data) => {
      let msg; try { msg = JSON.parse(data.toString()); } catch (_) { return; }
      if (msg[0] === 'EVENT') {
        const ev = msg[2];
        if (!ev || !ev.id) return;
        if (!events.has(ev.id)) events.set(ev.id, { event: ev, relays: new Set() });
        events.get(ev.id).relays.add(url.replace('wss://', ''));
      }
    });
    ws.on('error', () => { clearTimeout(timer); finish(); });
    ws.on('close', () => { clearTimeout(timer); finish(); });
  });
}

function tag(ev, name) { const t = ev.tags.find((x) => x[0] === name); return t ? t[1] : null; }
function tagsAll(ev, name) { return ev.tags.filter((x) => x[0] === name).map((x) => x[1]); }

(async () => {
  await Promise.all(RELAYS.map(collectFromRelay));

  for (const oid of ORDERS) {
    console.log('\n================================================================');
    console.log('ORDER', oid);
    console.log('================================================================');
    const rel = [...events.values()].filter(({ event }) => {
      const d = tag(event, 'd') || '';
      const r = tagsAll(event, 'r');
      const orderIdTag = tag(event, 'orderId');
      return d === oid || d.startsWith(oid + '_') || r.includes(oid) || orderIdTag === oid;
    }).sort((a, b) => a.event.created_at - b.event.created_at);

    if (rel.length === 0) { console.log('  (nenhum evento encontrado)'); continue; }

    const accepts = new Set();
    let hasComplete = false;
    let lastStatus = null;
    let disputeOpenedAt = null;
    let completeAt = null;
    const evidenceBySender = {};

    for (const { event, relays } of rel) {
      const when = new Date(event.created_at * 1000).toISOString();
      const d = tag(event, 'd') || '';
      let content = {};
      try { content = JSON.parse(event.content); } catch (_) { content = { _raw: (event.content || '').slice(0, 60) }; }
      const ts = tagsAll(event, 't').join(',');
      let line = `\n[${when}] kind=${event.kind} by=${event.pubkey.slice(0, 8)} d="${d}"`;
      line += `\n    #t=[${ts}] relays=${[...relays].join('|')}`;
      const interesting = ['type', 'status', 'providerId', 'userPubkey', 'publishedBy', 'amount', 'reason', 'newStatus', 'cancelReason', 'adminPubkey'];
      const kv = interesting.filter((k) => content[k] !== undefined && content[k] !== null && content[k] !== '')
        .map((k) => `${k}=${typeof content[k] === 'string' ? content[k].slice(0, 60) : content[k]}`);
      if (kv.length) line += `\n    ${kv.join(' | ')}`;
      if (content.status) lastStatus = content.status;
      if (event.kind === 1) {
        const isEvid = ts.includes('bro-disputa-evidencia');
        const isDisp = ts.includes('bro-disputa') && !isEvid;
        const enc = content.encrypted || content.encryption ? 'ENCRYPTED' : 'plaintext';
        line += `\n    >>> KIND1 ${isEvid ? 'EVIDENCE' : isDisp ? 'DISPUTE-NOTE' : 'note'} (${enc}) sender=${event.pubkey.slice(0, 8)} p=[${tagsAll(event, 'p').map((p) => p.slice(0, 8)).join(',')}]`;
        if (isEvid) evidenceBySender[event.pubkey.slice(0, 8)] = (evidenceBySender[event.pubkey.slice(0, 8)] || 0) + 1;
        if (isDisp && !disputeOpenedAt) disputeOpenedAt = when;
      }
      if (event.kind === 30079) { accepts.add(event.pubkey); line += '\n    >>> ACCEPT'; }
      if (event.kind === 30081) { hasComplete = true; completeAt = when; line += '\n    >>> COMPLETE (comprovante existe; imagem cifrada p/ usuário)'; }
      console.log(line);
    }

    console.log(`\n  --- RESUMO ${oid.slice(0, 8)} ---`);
    console.log(`  Provedores que aceitaram (kind 30079): ${accepts.size}${accepts.size > 1 ? '  ⚠️ DUPLICIDADE!' : ''}`);
    [...accepts].forEach((p) => console.log(`    - ${p}`));
    console.log(`  Comprovante (kind 30081) enviado: ${hasComplete ? `SIM (${completeAt})` : 'NÃO'}`);
    console.log(`  Último status visto: ${lastStatus || '(?)'}`);
    console.log(`  Disputa aberta em: ${disputeOpenedAt || '(sem nota de disputa)'}`);
    console.log(`  Evidências por remetente: ${JSON.stringify(evidenceBySender)}`);
    console.log(`  Total de eventos: ${rel.length}`);
  }
  process.exit(0);
})();

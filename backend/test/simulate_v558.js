/**
 * simulate_v558.js — Realistic end-to-end simulation of the v558 dispute agent.
 *
 * Run with: node backend/test/simulate_v558.js
 *
 * Exercises:
 *  - paymentVerifier: PIX BR Code (valid + tampered), E2E (valid + invalid), boleto length check
 *  - disputeAgentService._buildDbFindings (B2)
 *  - disputeAgentService._buildFlowFindings (B1)
 *  - disputeAgentService._buildPaymentFindings (B4)
 *  - disputeAgentService._combineResults A11 hard guard (Tier 1 demotion)
 *  - Full analyzeDispute path with mocked LLM
 */

const path = require('path');
process.chdir(path.join(__dirname, '..')); // run from backend/

const paymentVerifier = require('../services/paymentVerifier');
const db = require('../models/database');
const agentMod = require('../services/disputeAgentService');
const agent = agentMod; // exported instance? check

// disputeAgentService exports the class directly?  Read its exports:
const inspectExports = Object.keys(require('../services/disputeAgentService'));

let pass = 0, fail = 0;
const log = (label, ok, detail) => {
  if (ok) { pass++; console.log(`  ✅ ${label}`); }
  else    { fail++; console.log(`  ❌ ${label}${detail ? '  → ' + detail : ''}`); }
};

// ============================================================
// 1. paymentVerifier
// ============================================================

console.log('\n=== 1. paymentVerifier ===');

// Helper: CRC16-CCITT to build a valid BR Code
function crc16Ccitt(str) {
  let crc = 0xFFFF;
  for (let i = 0; i < str.length; i++) {
    crc ^= str.charCodeAt(i) << 8;
    for (let j = 0; j < 8; j++) {
      crc = (crc & 0x8000) ? ((crc << 1) ^ 0x1021) : (crc << 1);
      crc &= 0xFFFF;
    }
  }
  return crc;
}

// Build a minimal valid PIX BR Code for R$ 47.50
// 00 (Payload format) "01"
// 26 (Merchant Account) — "0014BR.GOV.BCB.PIX0111000.000.000-00"
// 52 "0000"
// 53 "986"
// 54 "47.50"
// 58 "BR"
// 59 "FULANO DE TAL"
// 60 "SAO PAULO"
// 62 "0500"  (additional info)
// 6304 + CRC
function tlv(id, val) {
  return id + String(val.length).padStart(2, '0') + val;
}
const merchantAccount = tlv('00', 'BR.GOV.BCB.PIX') + tlv('01', '00000000000');
const payload =
  tlv('00', '01') +
  tlv('26', merchantAccount) +
  tlv('52', '0000') +
  tlv('53', '986') +
  tlv('54', '47.50') +
  tlv('58', 'BR') +
  tlv('59', 'FULANO DE TAL') +
  tlv('60', 'SAO PAULO') +
  tlv('62', tlv('05', '***'));
const toCrc = payload + '6304';
const crc = crc16Ccitt(toCrc).toString(16).toUpperCase().padStart(4, '0');
const validBrCode = toCrc + crc;

console.log('  (synthetic PIX BR Code, ' + validBrCode.length + ' chars)');
const r1 = paymentVerifier.verifyPixBrCode(validBrCode, { expectedAmountBrl: 47.50 });
log('valid PIX BR Code parses & CRC matches', r1.valid && r1.parsed.amount === '47.50',
    `valid=${r1.valid} amount=${r1.parsed && r1.parsed.amount} findings=${JSON.stringify(r1.findings)}`);

// Tampered: change a digit in the amount but keep CRC unchanged → CRC mismatch
const tampered = validBrCode.replace('5403', '5403').replace('47.50', '99.99');
const r2 = paymentVerifier.verifyPixBrCode(tampered, { expectedAmountBrl: 47.50 });
log('tampered PIX BR Code → CRC mismatch flag',
    !r2.valid && r2.findings.some(f => f.id === 'pix_crc_mismatch'),
    `findings=${JSON.stringify(r2.findings)}`);

// Amount mismatch (CRC valid, but expected is different)
const r3 = paymentVerifier.verifyPixBrCode(validBrCode, { expectedAmountBrl: 100.00 });
log('PIX BR Code amount mismatch flag',
    r3.findings.some(f => f.id === 'pix_amount_mismatch'),
    `findings=${JSON.stringify(r3.findings)}`);

// Valid E2E
const validE2e = 'E12345678' + '202604261430' + 'ABC12345678';
const r4 = paymentVerifier.verifyPixE2E(validE2e, { orderCreatedAt: '2026-04-26T14:25:00Z' });
log('valid E2E recognized', r4.valid, `findings=${JSON.stringify(r4.findings)}`);

// Invalid E2E (wrong shape)
const r5 = paymentVerifier.verifyPixE2E('NOT_AN_E2E');
log('invalid E2E rejected', !r5.valid && r5.findings.some(f => f.id === 'e2e_format'),
    JSON.stringify(r5.findings));

// E2E far from order date (>48h)
const r6 = paymentVerifier.verifyPixE2E(validE2e, { orderCreatedAt: '2025-01-01T00:00:00Z' });
log('E2E datetime-far-from-order flag',
    r6.findings.some(f => f.id === 'e2e_datetime_far_from_order'),
    JSON.stringify(r6.findings));

// verifyAny dispatch
const r7 = paymentVerifier.verifyAny(validBrCode, { expectedAmountBrl: 47.50 });
log('verifyAny detects pix_brcode', r7.type === 'pix_brcode' && r7.valid);

const r8 = paymentVerifier.verifyAny(validE2e);
log('verifyAny detects pix_e2e', r8.type === 'pix_e2e');

const r9 = paymentVerifier.verifyAny('garbage');
log('verifyAny unknown rejected', r9.type === 'unknown' && !r9.valid);

// ============================================================
// 2. Inspect agent module exports
// ============================================================
console.log('\n=== 2. agent module shape ===');
console.log('  exports:', inspectExports);

// disputeAgentService exports a singleton
const dispAgent = require('../services/disputeAgentService');
const isInst = typeof dispAgent.analyzeDispute === 'function';
log('disputeAgentService exports singleton', isInst, 'has analyzeDispute=' + isInst);

// ============================================================
// 3. _buildDbFindings (B2)
// ============================================================
console.log('\n=== 3. _buildDbFindings (B2 DB cross-check) ===');

const ORDER_ID_OK = 'order-test-ok';
const ORDER_ID_MISMATCH = 'order-test-mismatch';
const ORDER_ID_MISSING = 'order-test-missing';

db.orders.set(ORDER_ID_OK, {
  orderId: ORDER_ID_OK,
  amountBrl: 47.50,
  amountSats: 8000,
  billType: 'pix',
  providerId: 'provider-pubkey',
  acceptedAt: '2026-04-25T10:00:00Z',
});
db.escrows.set(ORDER_ID_OK, { orderId: ORDER_ID_OK, sats: 800 });

db.orders.set(ORDER_ID_MISMATCH, {
  orderId: ORDER_ID_MISMATCH,
  amountBrl: 47.50,
  amountSats: 8000,
  billType: 'pix',
});
// no escrow row → expect db_no_escrow

const okFindings = dispAgent._buildDbFindings({
  orderId: ORDER_ID_OK,
  amount_brl: 47.50,
  amount_sats: 8000,
  payment_type: 'pix',
});
log('matching DB → no findings', okFindings.length === 0,
    'findings=' + JSON.stringify(okFindings));

const mismatchFindings = dispAgent._buildDbFindings({
  orderId: ORDER_ID_MISMATCH,
  amount_brl: 99.99,            // mismatch
  amount_sats: 9999,            // mismatch
  payment_type: 'boleto',       // mismatch
});
const ids = mismatchFindings.map(f => f.id);
log('amount_brl mismatch flagged', ids.includes('db_amount_brl_mismatch'));
log('amount_sats mismatch flagged', ids.includes('db_amount_sats_mismatch'));
log('payment_type mismatch flagged', ids.includes('db_payment_type_mismatch'));
log('missing escrow flagged', ids.includes('db_no_escrow'));

const missingFindings = dispAgent._buildDbFindings({
  orderId: ORDER_ID_MISSING,
  amount_brl: 50,
  amount_sats: 5000,
  payment_type: 'pix',
});
log('missing order flagged', missingFindings.some(f => f.id === 'db_order_missing'));

// ============================================================
// 4. _buildFlowFindings (B1 flow compliance)
// ============================================================
console.log('\n=== 4. _buildFlowFindings (B1) ===');

// Scenario: provider opened dispute on order that was never accepted
const ORDER_UNACCEPTED = 'order-test-unaccepted';
db.orders.set(ORDER_UNACCEPTED, {
  orderId: ORDER_UNACCEPTED,
  amountBrl: 50,
  amountSats: 7000,
  billType: 'pix',
  providerId: null,    // never accepted
});
const flowF1 = dispAgent._buildFlowFindings({
  orderId: ORDER_UNACCEPTED,
  openedBy: 'provider',
  createdAt: new Date().toISOString(),
  user_evidence_nip44: '',
});
log('provider-on-unaccepted flagged',
    flowF1.some(f => f.id === 'flow_provider_dispute_unaccepted' && f.favors === 'user'),
    JSON.stringify(flowF1));

// Scenario: proof submitted AFTER dispute opened
const ORDER_PROOF_AFTER = 'order-test-proof-after';
const disputeTime = new Date('2026-04-26T10:00:00Z');
db.orders.set(ORDER_PROOF_AFTER, {
  orderId: ORDER_PROOF_AFTER,
  amountBrl: 50,
  amountSats: 7000,
  billType: 'pix',
  providerId: 'provider-pubkey',
  acceptedAt: '2026-04-25T08:00:00Z',
  proofReceivedAt: '2026-04-26T11:00:00Z', // 1h AFTER dispute opened
});
const flowF2 = dispAgent._buildFlowFindings({
  orderId: ORDER_PROOF_AFTER,
  openedBy: 'user',
  createdAt: disputeTime.toISOString(),
  user_evidence_nip44: 'x'.repeat(200),
});
log('proof-after-dispute flagged',
    flowF2.some(f => f.id === 'flow_proof_after_dispute' && f.favors === 'user'),
    JSON.stringify(flowF2));

// Scenario: provider accepted but no response in 72h
const ORDER_72H_SILENCE = 'order-test-silence';
db.orders.set(ORDER_72H_SILENCE, {
  orderId: ORDER_72H_SILENCE,
  amountBrl: 50,
  amountSats: 7000,
  billType: 'pix',
  providerId: 'provider-pubkey',
  acceptedAt: '2026-04-22T08:00:00Z', // > 72h before now
  proofReceivedAt: null,
});
const flowF3 = dispAgent._buildFlowFindings({
  orderId: ORDER_72H_SILENCE,
  openedBy: 'user',
  createdAt: new Date('2026-04-26T10:00:00Z').toISOString(),
  user_evidence_nip44: '',
});
log('72h-silence flagged',
    flowF3.some(f => f.id === 'flow_no_provider_response_72h'),
    JSON.stringify(flowF3));

// Scenario: no evidence from disputer
const flowF4 = dispAgent._buildFlowFindings({
  orderId: 'whatever',
  openedBy: 'user',
  createdAt: new Date().toISOString(),
  // no user_evidence_nip44
});
log('no-evidence-from-disputer flagged',
    flowF4.some(f => f.id === 'flow_no_evidence_from_disputer'));

// ============================================================
// 5. _buildPaymentFindings (B4)
// ============================================================
console.log('\n=== 5. _buildPaymentFindings (B4) ===');

const payF1 = dispAgent._buildPaymentFindings({
  pix_brcode: validBrCode,
  amount_brl: 47.50,
  createdAt: '2026-04-26T14:25:00Z',
});
log('valid BR Code → "valid" finding present',
    payF1.some(f => f.id === 'payment_pix_brcode_valid'),
    JSON.stringify(payF1));

const payF2 = dispAgent._buildPaymentFindings({
  pix_brcode: tampered,  // CRC bad
  amount_brl: 47.50,
});
log('tampered BR Code → CRC mismatch surfaced',
    payF2.some(f => /crc_mismatch/.test(f.id) && f.severity === 'high'),
    JSON.stringify(payF2));

const payF3 = dispAgent._buildPaymentFindings({
  pix_e2e: validE2e,
  amount_brl: 47.50,
  createdAt: '2026-04-26T14:25:00Z',
});
log('valid E2E surfaced',
    payF3.some(f => f.id === 'payment_pix_e2e_valid'),
    JSON.stringify(payF3));

const payF4 = dispAgent._buildPaymentFindings({});
log('no codes → no findings', payF4.length === 0);

// ============================================================
// 6. _combineResults A11 hard guard
// ============================================================
console.log('\n=== 6. _combineResults A11 hard guard ===');

// A. Heuristic-only with high confidence → must NOT reach Tier 1
{
  const out = dispAgent._combineResults(
    { ruleId: 'rule-x', suggestion: 'resolved_user', confidence: 0.92, reason: 'r' },
    null,
    { db_findings: [], flow_findings: [], payment_findings: [] }
  );
  log('heuristic-only 0.92 → Tier 2 (A11 demotes)', out.tier === 2,
      'tier=' + out.tier + ' conf=' + out.confidence);
}

// B. Heuristic 0.92 + LLM 0.92, both agree → Tier 1 allowed
{
  const out = dispAgent._combineResults(
    { ruleId: 'r', suggestion: 'resolved_user', confidence: 0.92, reason: 'h' },
    { suggestion: 'resolved_user', confidence: 0.92, reason: 'l', analysis: '', risk_factors: [] },
    { db_findings: [], flow_findings: [], payment_findings: [] }
  );
  log('h=0.92 + llm=0.92 + agree → Tier 1', out.tier === 1,
      'tier=' + out.tier + ' conf=' + out.confidence.toFixed(2));
}

// C. Heuristic 0.92 + LLM 0.70 → guard demotes
{
  const out = dispAgent._combineResults(
    { ruleId: 'r', suggestion: 'resolved_user', confidence: 0.92, reason: 'h' },
    { suggestion: 'resolved_user', confidence: 0.70, reason: 'l', analysis: '', risk_factors: [] },
    { db_findings: [], flow_findings: [], payment_findings: [] }
  );
  log('h=0.92 + llm=0.70 → Tier 2 (LLM below 0.85)', out.tier === 2,
      'tier=' + out.tier);
}

// D. Heuristic 0.92 + LLM 0.92 disagreeing → Tier 2 (no agreement)
{
  const out = dispAgent._combineResults(
    { ruleId: 'r', suggestion: 'resolved_user', confidence: 0.92, reason: 'h' },
    { suggestion: 'resolved_provider', confidence: 0.92, reason: 'l', analysis: '', risk_factors: [] },
    { db_findings: [], flow_findings: [], payment_findings: [] }
  );
  log('h=0.92 + llm=0.92 disagree → not Tier 1', out.tier !== 1,
      'tier=' + out.tier);
}

// E. ScoreDelta from findings should subtract from confidence
{
  const out = dispAgent._combineResults(
    { ruleId: 'r', suggestion: 'resolved_user', confidence: 0.90, reason: 'h' },
    { suggestion: 'resolved_user', confidence: 0.90, reason: 'l', analysis: '', risk_factors: [] },
    {
      db_findings: [{ id: 'db_amount_brl_mismatch', severity: 'high', detail: 'x', scoreDelta: -0.30 }],
      flow_findings: [],
      payment_findings: [],
    }
  );
  log('high-severity DB mismatch lowers confidence',
      out.confidence < 0.90,
      'conf=' + out.confidence.toFixed(2));
}

// F. Strong flow override flips suggestion
{
  const out = dispAgent._combineResults(
    { ruleId: 'r', suggestion: 'resolved_provider', confidence: 0.80, reason: 'h' },
    { suggestion: 'resolved_provider', confidence: 0.80, reason: 'l', analysis: '', risk_factors: [] },
    {
      db_findings: [],
      flow_findings: [{ id: 'flow_proof_after_dispute', severity: 'high', favors: 'user', detail: 'x', scoreDelta: -0.25 }],
      payment_findings: [],
    }
  );
  log('strong flow_favors=user flips suggestion to resolved_user',
      out.suggestion === 'resolved_user',
      'suggestion=' + out.suggestion);
}

// G. Skip path
{
  const out = dispAgent._combineResults(
    { ruleId: 'duplicate_dispute', suggestion: 'skip', confidence: 1.0, reason: 'r' },
    null,
    {}
  );
  log('skip suggestion → tier 0', out.tier === 0 && out.suggestion === 'skip');
}

// ============================================================
// 7. Full analyzeDispute end-to-end (heuristic-only path, no LLM)
// ============================================================
console.log('\n=== 7. analyzeDispute (full path, no LLM) ===');

(async () => {
  // Make sure no LLM kicks in
  delete process.env.LLM_API_KEY;

  // Scenario: realistic PROVIDER-FILED dispute on UNACCEPTED order with TAMPERED BR code
  const realDispute = {
    orderId: 'sim-realistic-001',
    openedBy: 'provider',
    reason: 'usuário não pagou',
    description: 'Usuário não enviou comprovante e não respondeu',
    amount_brl: 47.50,
    amount_sats: 8000,
    payment_type: 'pix',
    pix_brcode: tampered,  // tampered (CRC bad)
    user_evidence_nip44: '',
    createdAt: new Date('2026-04-26T10:00:00Z').toISOString(),
  };
  // Create matching DB row but unaccepted
  db.orders.set('sim-realistic-001', {
    orderId: 'sim-realistic-001',
    amountBrl: 47.50,
    amountSats: 8000,
    billType: 'pix',
    providerId: null, // unaccepted
  });

  const analysis = await dispAgent.analyzeDispute(realDispute, {});
  log('analyzeDispute returned object', !!analysis);
  if (analysis) {
    log('attached dbFindings on analysis', Array.isArray(analysis.dbFindings) || analysis.dbFindings !== undefined);
    log('attached flowFindings on analysis', Array.isArray(analysis.flowFindings) || analysis.flowFindings !== undefined);
    log('attached paymentFindings on analysis', Array.isArray(analysis.paymentFindings) || analysis.paymentFindings !== undefined);
    log('flow flagged provider-on-unaccepted',
        analysis.flowFindings && analysis.flowFindings.some(f => f.id === 'flow_provider_dispute_unaccepted'),
        JSON.stringify(analysis.flowFindings));
    log('payment flagged tampered code',
        analysis.paymentFindings && analysis.paymentFindings.some(f => /crc_mismatch/.test(f.id)));
    log('A11 guard kept heuristic-only out of Tier 1',
        analysis.tier !== 1, 'tier=' + analysis.tier);
    console.log('  Final: tier=' + analysis.tier +
                ' suggestion=' + analysis.suggestion +
                ' confidence=' + (analysis.confidence || 0).toFixed(2) +
                ' reason="' + analysis.reason + '"');
  }

  // Scenario: skip when already resolved
  const skipDispute = {
    orderId: 'sim-realistic-002',
    openedBy: 'user',
    reason: 'r',
    amount_brl: 10,
    amount_sats: 1000,
    payment_type: 'pix',
  };
  db.orders.set('sim-realistic-002', {
    orderId: 'sim-realistic-002',
    amountBrl: 10, amountSats: 1000, billType: 'pix',
  });
  // First analysis
  const a1 = await dispAgent.analyzeDispute(skipDispute, {});
  // Mark as resolved
  if (a1) {
    a1.resolvedBy = 'human';
    a1.humanResolution = 'resolved_user';
  }
  // Force re-analysis trigger
  if (a1) a1.needsReanalysis = true;
  const a2 = await dispAgent.analyzeDispute(skipDispute, {});
  log('re-analysis of resolved dispute returns skip',
      a2 && a2.suggestion === 'skip',
      'suggestion=' + (a2 && a2.suggestion));

  // ============================================================
  console.log('\n=== SUMMARY ===');
  console.log(`  ${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
})();

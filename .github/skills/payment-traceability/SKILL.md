---
name: payment-traceability
description: Payment traceability and fee auditing for the Bro app. Use when investigating duplicate fees, tracing where a Lightning payment came from, reconciling platform fees, debugging "taxa duplicada", "gasto duplo", "de onde veio esse pagamento", or cross-referencing the app wallet with an external wallet statement (coinos, Spark, etc). Documents the preimage key that links both sides.
---

# Payment Traceability — Bro App

## Purpose

Answers the question **"de onde veio esse pagamento?"** with evidence, not
guesses. Prevents false accusations of duplicate charges and enables real
support/dispute resolution.

## When to Use

Activate when:
- Investigating duplicate fees or "gasto duplo"
- Tracing a payment from the app wallet to an external wallet statement
- Modifying `sendPlatformFee`, `recordFee`, `_reconcilePlatformFees`
- Working with `[PAY-TRACE]` or `[FEE-TRACE]` logs
- Debugging BRIX fee charges
- Cross-referencing `payments.csv` (coinos) with app history

---

## The Key Insight: `preimage`, not `paymentHash`

**This cost hours to discover. Do not repeat the mistake.**

The app's `paymentHash` (from the Spark SDK) does **NOT** match the `ref` field
in the coinos statement. Comparing them yields **zero matches** and leads to the
false conclusion that the payments are unrelated.

The relationship is:

```
SHA256(preimage) == paymentHash == 'ref' no extrato da coinos
```

The coinos `ref` **is the preimage**, not the payment hash.

### Proof (26/11/2026)

```
Nov 26 1 sats ref=64dfacd133fe -> sha256=7954a2a9f856  *** MATCH ***
Nov 26 1 sats ref=c0ac28a189ea -> sha256=8e0b401a918d  *** MATCH ***
Nov 26 1 sats ref=a64b0d9cd29b -> sha256=de1a6ea2fce3  *** MATCH ***
Nov 26 1 sats ref=85654a16cc31 -> sha256=a4bffdc7b4c1  *** MATCH ***
Nov 26 1 sats ref=60b617710441 -> sha256=fe5bf8a55b96  *** MATCH ***
Nov 26 1 sats ref=6fac7ecfb6ad -> sha256=f63ad4b2783a  *** MATCH ***
Nov 26 1 sats ref=384148e7c36a -> sha256=7c9f1fb961fc  *** MATCH ***
Nov 26 1 sats ref=18ce702d6761 -> sha256=e0aa80e9c114  *** MATCH ***
```

**8 de 8.** Timestamps also match within 1–8 seconds.

### How to test the hypothesis

```powershell
$csv = Import-Csv "payments.csv"
$sha = [System.Security.Cryptography.SHA256]::Create()
foreach ($r in $csv) {
  $bytes = [byte[]]::new(32)
  for ($i=0; $i -lt 32; $i++) { $bytes[$i] = [Convert]::ToByte($r.ref.Substring($i*2,2),16) }
  $h = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
  Write-Host "$($r.amount) sats ref=$($r.ref.Substring(0,12)) -> sha256=$($h.Substring(0,12))"
}
```

---

## The three identifiers the SDK exposes

Every Lightning payment has **three** distinct identifiers. Confusing them is
the source of most traceability bugs.

| Campo | O que é | Quem vê |
|---|---|---|
| `sparkId` | `payment.id` — ID interno do Spark | só o app |
| `htlc` | hash do HTLC (o que o SDK chama de `paymentHash`) | remetente |
| `invoiceHash` | `payment_hash` extraído do bolt11 | **ambos** |
| `preimage` | prova criptográfica | **ambos** (destino vê como `ref`) |

**`invoiceHash` == `htlc`** na prática (o SDK devolve o mesmo valor). Mas
**nenhum dos dois** é o que o destinatário vê no extrato — só o `preimage` é.

---

## Logs de rastreabilidade

### `[PAY-TRACE]` — histórico de pagamentos

Emitido em `breez_provider.dart` dentro de `listPayments()`:

```
[PAY-TRACE] 2026-11-26T10:47:15.000 1 sats
  sparkId=01a2181c-36cf-7cf2-894b-62b7805a3d63
  htlc=7954a2a9f856242e2ba6901bd13e52020f4752ad2fc6b613af12619a812015e7
  invoiceHash=7954a2a9f856242e2ba6901bd13e52020f4752ad2fc6b613af12619a812015e7
  preimage=64dfacd133fe6b1f78ab98b189c7d5a8172b71666fd337bc0179da6c3e94c9f2
  desc=""
```

**Formato estável para grep.** Não mude sem atualizar esta skill.

### `[FEE-TRACE]` — origem de cada taxa

Emitido em `platform_fee_service.dart` (antes de pagar) e em
`brix_relay_service.dart` (caminho BRIX):

```
[FEE-TRACE] order=<orderId> amount=<sats> hash=<paymentHash> dest=<addr>
[FEE-TRACE] brix_send order=brix_send_<paymentHash> amount=<sats> fee=<sats> pct=0.005
[FEE-TRACE] reconcile order=<orderId> amount=<sats> fee=<sats> ref=<iso>
```

**Sem isso é impossível saber qual ordem gerou um recebimento.**

---

## Como cruzar app ↔ extrato externo

```powershell
# 1. Extrair preimages do logcat
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$log = & $adb -s <device> logcat -d -s flutter 2>&1 | Out-String
$pres = [regex]::Matches($log, 'preimage=([0-9a-f]{64})') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

# 2. Comparar com o CSV
$csv = Import-Csv "payments.csv"
foreach ($p in $pres) {
  $m = $csv | Where-Object { $_.ref -eq $p }
  if ($m) { Write-Host "MATCH $($m.created) $($m.amount) sats" }
}
```

### Interpretando o resultado

- **Match** → o pagamento saiu deste aparelho, naquele instante.
- **Sem match** → pode ser: (a) de outro dispositivo, (b) anterior ao buffer do
  logcat, (c) não é taxa do Bro.

**Não conclua "duplicado" sem antes verificar (a) e (b).**

---

## Caso real: as 8 taxas de 1 sat (26/11/2026)

**Suspeita:** as correções estavam gerando gasto duplo.

**Investigação:**
1. 8 recebimentos de 1 sat na coinos, 09:48–10:47
2. App tinha 8 envios de 1 sat no mesmo intervalo
3. `paymentHash` vs `ref`: **zero matches** → parecia não relacionado
4. `SHA256(ref)` vs `paymentHash`: **8 de 8 matches** → são os mesmos

**Veredito:** **não são duplicadas.** Cada uma tem `sparkId`, `htlc` e
`preimage` únicos. São 8 envios BRIX distintos, cada um cobrando 0,5%:

| Envio | 0,5% | Arredonda |
|---|---|---|
| 200 sats | 1,00 | 1 sat |
| 341 sats | 1,70 | 2 sats |
| 415 sats | 2,07 | 2 sats |

A reconciliação **não rodou** (`Nenhuma ordem precisou ser reconciliada`).

**Total final:** 11 de 14 recebimentos do CSV batem. Os 3 restantes (686 sats e
2×2 sats de 25/11) **não existem no histórico deste aparelho** — vieram de
outro dispositivo.

---

## Armadilhas conhecidas

### 1. `timestamp` no mapa de pagamentos é `DateTime`, não `int`

```dart
// ERRADO — lança
final ms = p['timestamp'] as int;

// CERTO
int tsMsOf(Map<String, dynamic> p) {
  final v = p['timestamp'];
  if (v is DateTime) return v.millisecondsSinceEpoch;
  if (v is num) return v.toInt();
  return 0;
}
```

### 2. `FEE-TRACE=0` não prova nada

Se os pagamentos ocorreram **antes** do build que adicionou o trace, não há log.
Verifique a data do build vs a data do pagamento.

### 3. BRIX usa `orderId` único por envio

```dart
orderId: 'brix_send_$paymentHash'  // único por envio
```

O lock `_paidOrderIds` **nunca bloqueia** reenvio BRIX. A deduplicação real é o
`settled`/`pending` em `brix_relay_service.dart`.

### 4. `feeFoundInWallet` é frágil com 1 sat

Procura envio de valor exato na janela [ref−2h, +48h]. Com taxas de 1 sat,
**qualquer** envio de 1 sat faz match. Não use como prova isolada.

### 5. `_reconcilePlatformFees` nunca rodou em produção

0 logs `FeeReconcile` em toda a sessão. A heurística valor+janela é frágil.
Se for mexer, adicione guarda mais forte.

---

## Checklist antes de afirmar "taxa duplicada"

- [ ] Extraiu o `preimage` de cada pagamento?
- [ ] Testou `SHA256(ref)` contra o `paymentHash`?
- [ ] Verificou se os `sparkId` são distintos? (mesmo sparkId = retry real)
- [ ] Verificou se os pagamentos são anteriores ao build com trace?
- [ ] Verificou se vieram de outro dispositivo?
- [ ] Confirmou que a reconciliação rodou? (`FeeReconcile` no log)

**Só depois disso** afirme duplicidade.

---

## Referências

- `docs/internal/LICOES_APRENDIDAS_NOV2026.md` — seção 3
- `docs/internal/MAPA_FLUXO_DINHEIRO.md` — como o dinheiro circula
- `lib/providers/breez_provider.dart` — `[PAY-TRACE]`, `tsMsOf`
- `lib/services/platform_fee_service.dart` — `[FEE-TRACE]`, `recordFee`
- `lib/services/brix_relay_service.dart` — caminho BRIX
- `lib/providers/order_provider.dart` — `_reconcilePlatformFees`

# Revisão Consolidada — v884–v887

> **Para:** integrador, contingência e Carol.
> **Branch:** `test/v827-no-expiry` @ `8362cfa`
> **Data:** 28/11/2026 · Build 887

---

## 1. O que mudou desde a última revisão

O integrador apontou **2 bloqueadores**. Ambos eram reais. Corrigidos no v887.

| Bloqueador | Confirmado? | Corrigido? |
|---|---|---|
| **1** — poll do BRIX podia morrer de vez | ✅ **sim** | ✅ v887 |
| **2** — batch `#d` vazio com >15 ordens | ✅ **sim** (P1 pré-existente) | ✅ v887 |
| **Testes de fachada** | ✅ **sim** (39 tautologias) | ✅ substituídos por 27 reais |

---

## 2. Bloqueador 1 — poll do BRIX podia morrer

### O problema (confirmado no código)

```dart
// v884 (ERRADO)
_pollTimer = Timer(delay, () async {
  await _poll();          // ← se lançar, a cadeia morre
  _scheduleNextPoll();    // ← nunca roda
});
```

E `_retryPendingOutgoingFees()` está **fora** do try/catch do `_pollInner`:

```dart
// brix_relay_service.dart:577
await _retryPendingOutgoingFees();   // ← fora do try
```

Se lançar (`as num` em entrada malformada, `StateError` do
`_removePendingOutgoingFee`), o poll **para de vez** até o próximo
resume/FCM. Isso para o claim offline e a captura de invoice request.

**O invariante 1 estava intacto na letra** (nenhum `return` novo antes do
claim), mas o **efeito** era exatamente o que ele protege.

### A correção

```dart
// v887 (CORRETO)
_pollTimer = Timer(delay, () async {
  try {
    await _poll();
  } catch (e) {
    broLog('[BRIX-RELAY] poll lançou (cadeia continua): $e');
  } finally {
    _scheduleNextPoll();   // ← SEMPRE
  }
});
```

**Também:** `_lastActivityAt = DateTime.now()` em `start()` e `restart()`.
Quem volta de 30 min em background caía direto no degrau de 60s justo quando
abre o app para receber.

### Sobre a métrica "1 poll em 4,5 min"

O integrador está certo: eu contei a linha de log que só sai a cada 20 polls
(`_pollCount % 20 == 1`). O número real é ~37 polls em 4,5 min, não 1.

**O ganho real:** ~12× **depois** de 8 min ocioso. Antes disso, a escada é
gradual (5→10→20→40→60s).

---

## 3. Bloqueador 2 — batch `#d` vazio (P1 pré-existente)

### O bug (provado)

```dart
ids.sublist(i, i + 15 > ids.length ? ids.length : i)   // ← errado
```

Quando o batch está **cheio** (`i + 15 <= ids.length`), o ternário cai no
`else` que é `i` → `sublist(i, i)` = **lista vazia**.

**Prova em Python:**
```
i=0, end=0, batch=[] (len=0)      ← bugado
correto: end=15, batch len=15
```

### O impacto (medido pelo integrador nos relays)

| Relay | Comportamento com `'#d': []` |
|---|---|
| apexcord, bro-relay2 (nostr-rs) | **SEM FILTRO** → 50 × 30081 alheios, **2,7 MB por relay** |
| primal, damus (strfry) | devolve nada |

**No aparelho da Carol (18 ordens ativas):**
- **15 de 18 ordens sem a busca `#d`** — justamente o que resolve "travado em
  Bro encontrado" das ordens que vieram da API
- **~5,4 MB de lixo por sync** (comprovantes de outros usuários, cada um com
  verificação de assinatura e `jsonDecode`)

**Provável contribuinte do aquecimento** que a Carol reportou no iOS.

### A correção

```dart
ids.sublist(i, i + 15 > ids.length ? ids.length : i + 15)   // ← i + 15
if (batch.isEmpty) continue;   // ← defesa
```

**Origem:** `git blame` mostra que o bug entrou no v812/v815d (16-17/11).
Não é regressão minha — é herdado.

---

## 4. Testes de fachada → testes reais

O integrador está certo: os 39 testes anteriores **não importavam o app**.

| Antes (fachada) | Depois (real) |
|---|---|
| `const x = true; expect(x, isTrue)` | Importa `BrixRelayService`, exercita `nextPollDelayForTest` |
| Réplica da lógica no teste | Réplica **da expressão exata** + prova que a antiga falha |
| Nenhum WebSocket | **`HttpServer` + WebSocket real**, protocolo NIP-01 |

### Os 27 testes novos

| Arquivo | Testes | O que cobre |
|---|---|---|
| `v887_brix_backoff_real_test.dart` | 8 | Escada real, teto, monotonicidade, economia |
| `v887_batch_d_bug_test.dart` | 14 | Prova o bug, valida cobertura de 18 ids |
| `v887_multi_req_real_test.dart` | 5 | NIP-01 real: N REQ, N EOSE, roteamento, timeout, relay que fecha |

**`nextPollDelayForTest`** foi exposto com `@visibleForTesting` para permitir
o teste real.

---

## 5. Medição no aparelho (build 887)

| Métrica | 884 | 886 | **887** |
|---|---|---|---|
| CPU | 13.7% | 6.6% | **7.1%** |
| Temperatura AP | 33.2 °C | 33.2 °C | **33.2 °C** |
| BRIX Poll (2 min) | ~24 | 1 | **1** |
| `poll lançou` | — | — | **0** |
| `fetchOrderUpdates` | 3 | 3 | **3** |

**Nota:** o CPU do 887 (7.1%) é ligeiramente maior que o 886 (6.6%) porque o
fix do batch agora **faz a busca `#d` de verdade** (15 ordens que antes eram
puladas). É trabalho útil, não desperdício.

---

## 6. Gate

```
flutter analyze lib/                          → 0 erros
flutter test test/race test/integration       → 270/270
```

---

## 7. O que o integrador aprovou (mantido)

| Item | Status |
|---|---|
| v885 — cooldown de republicação | ✅ aprovado |
| v886 — mecanismo do multi-REQ | ✅ aprovado |
| Textos do tier | ✅ aprovado (confere com `requiredCollateralBrl: 0`) |

---

## 8. Follow-ups sugeridos pelo integrador (não bloqueiam)

| # | Item | Prioridade |
|---|---|---|
| 1 | Limite de 15 subscriptions por socket (primal = 20) | Média |
| 2 | Tratar mensagem `CLOSED` do relay | Média |
| 3 | Nome do tier em EN/ES (está em PT) | Baixa |

---

## 9. Sobre o resgate (contingência)

O integrador achou um detalhe importante: o rescue **rebaixa `uuid` de 11.1.1
para 9.0.1**, desfazendo a correção do v880.

**Regra para a extração:**

```powershell
# CERTO — só o arquivo de código
git checkout rescue/trabalho-orfao-28nov -- backend/services/disputeAgentService.js

# ERRADO — traria o downgrade de uuid
git checkout rescue/trabalho-orfao-28nov -- backend/
```

**Confirmado:** o `main` não mudou `disputeAgentService.js` desde a base do
rescue. Extração sem conflito.

**Decisão pendente da Carol:** autorizar a extração do `_buildLearningContext`.

---

## 10. Checklist antes do merge

```
[x] Bloqueador 1 corrigido (finally + reset de atividade)
[x] Bloqueador 2 corrigido (i + 15 + defesa de batch vazio)
[x] Testes de fachada substituídos por 27 reais
[x] Gate: 0 erros, 270/270
[x] Build 887 instalado e medido
[ ] Integrador re-audita os 2 diffs curtos
[ ] Build 887 validado no iOS (TestFlight interno)
[ ] Carol autoriza
```

---

## 11. O que o merge dispara

| Workflow | Roda? |
|---|---|
| `full-release` (TestFlight + GitHub Release público + Zapstore) | ✅ sim |
| `backend-deploy-flyio` | ❌ não (backend não mudou) |

`beta_groups` comentado → **não vai para testers externos**.

---

*Documento para revisão tripla. Nenhum merge executado.*

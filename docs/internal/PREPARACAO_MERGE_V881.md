# Preparação de Merge — `test/v827-no-expiry` → `main`

> **Status: NÃO EXECUTADO.** Aguardando auditoria externa e OK da Carol.
> Gerado em 28/11/2026, build 881.

---

## 1. Resumo executivo

| Item | Valor |
|---|---|
| Branch origem | `test/v827-no-expiry` |
| Branch destino | `main` |
| Commits à frente | **6** |
| Arquivos alterados | **54** |
| Conflitos de merge | **0** (verificado com `git merge-tree`) |
| Versão atual | `1.0.134+881` |
| Versão no `main` | `1.0.134+855` |
| Gate | `flutter analyze` 0 erros · `flutter test` **224/224** |

---

## 2. ⚠️ O QUE O MERGE DISPARA (leia antes de aprovar)

O `main` tem **dois workflows automáticos** no Codemagic. Mergear dispara os dois:

### 2.1 `full-release` — "Android + iOS (Testers)"

```yaml
triggering:
  events: [push]
  branch_patterns:
    - pattern: 'main'
      include: true
```

**O que faz:**
1. Roda `flutter test test/race test/integration` (gate)
2. Builda APK universal + APK arm64-v8a
3. **Publica no GitHub Releases** (`bro-latest.apk` + versionado)
4. **Publica no Zapstore**
5. Builda IPA
6. **`submit_to_testflight: true`** ← envia para TestFlight

**Respondendo à sua dúvida:** o merge **NÃO** vai para testers externos automaticamente, mas **VAI para TestFlight** (testadores internos iOS) e **publica o APK no GitHub Releases** (que é público — qualquer um baixa).

`submit_to_app_store: false` — não vai para a App Store.
`beta_groups` está **comentado** — não envia para grupo externo.

**Risco:** o APK no GitHub Releases fica público. Se você quer validar antes, precisa **desabilitar o `full-release` temporariamente** ou mergear em horário controlado.

### 2.2 `backend-deploy-flyio` — "Backend -> Fly.io (bro-api)"

```yaml
triggering:
  events: [push]
  branch_patterns:
    - pattern: 'main'
      include: true
```

**O que faz:** deploya o backend no Fly.io **se `backend/` mudou neste push**.

**Meu branch mudou `backend/package.json` e `backend/package-lock.json`** (qs/uuid) → **o deploy VAI rodar**.

**Risco:** o backend em produção recebe `qs 6.17.1` e `uuid 11.1.1`. Validei que o servidor sobe localmente, mas **não testei em produção**.

---

## 3. Opções de merge (escolha uma)

### Opção A — Merge direto (mais simples, mais risco)

```powershell
cd C:\Users\produ\Documents\GitHub\bro_app_v827_recovery
git checkout main
git pull origin main
git merge --no-ff test/v827-no-expiry
git push origin main
```

**Dispara:** `full-release` (TestFlight + GitHub Release + Zapstore) + `backend-deploy-flyio`.

**Quando usar:** se você já validou o build 881 no aparelho e aceita que o APK vá para o GitHub Releases.

### Opção B — Merge com workflows desabilitados (recomendado)

1. Editar `codemagic.yaml` no `main` **antes** do merge:
   - Comentar o `triggering` do `full-release`
   - Comentar o `triggering` do `backend-deploy-flyio`
2. Mergear
3. Validar
4. Reabilitar os workflows em um commit separado

**Vantagem:** controle total. Nada publica sem você mandar.

### Opção C — Merge em branch intermediária

```powershell
git checkout -b release/v881 main
git merge --no-ff test/v827-no-expiry
git push origin release/v881
```

**Dispara:** `ios-testers` (TestFlight apenas, sem APK público).

**Depois:** quando validado, mergear `release/v881` → `main`.

**Vantagem:** TestFlight para validar iOS, sem publicar APK público.

---

## 4. Pré-requisitos antes de qualquer merge

### 4.1 Reverter o trigger temporário

O `codemagic.yaml` tem um trigger temporário que **precisa ser revertido**:

```yaml
internal-test:
  triggering:
    events: [push]
    branch_patterns:
      - pattern: 'test/v827-no-expiry'   # ← TEMPORÁRIO
        include: true
```

**Reverter para:** `triggering: {}`

**Por quê:** senão todo push no branch dispara build macOS (consome minutos).

### 4.2 Confirmar que o build 881 foi validado

- [ ] Comprovante renderiza (`4e2c858a`)
- [ ] Pagamento funciona com Tor ligado
- [ ] Saldo real (não zero)
- [ ] CPU baixa / sem aquecimento
- [ ] R2 tier trial ativa sem garantia

### 4.3 Resolver as 2 pendências de outros agentes

| Pendência | Dono | Status |
|---|---|---|
| `perf-sync` mexeu em `getBalance`/`payInvoice`? | perf-sync | **desconhecido** |
| Quem fica com PERF-UI-1/2? | perf-ui | **desconhecido** |

**Se `perf-sync` mexeu em `breez_provider.dart`:** mergear o dele primeiro, eu rebaso.
**Se `perf-ui` já tem PERF-UI-1/2:** descarto as minhas.

---

## 5. O que o merge traz (6 commits)

| Commit | O que faz | Risco |
|---|---|---|
| `08f3bdb` | v879: comprovante (3 causas), status terminal, Tor no pagamento, saldo real, split 80/20 seguro | **Médio** — toca caminho de dinheiro |
| `a433ce3` | ci: trigger temporário | **Reverter** |
| `5583e27` | v880: 4 nits da auditoria | Baixo |
| `3fac871` | backend: qs/uuid (13→12 vulns) | **Médio** — deploy Fly |
| `327cd9c` | v881: PERF-UI-1/2 | Baixo |
| `fde6eee` | ci: internal-test manual-only | Já no main |

---

## 6. Verificações feitas

### 6.1 Conflitos

```
git merge-tree (merge-base) origin/main HEAD
→ 0 marcadores de conflito
```

### 6.2 Invariantes de dinheiro (do briefing)

| # | Invariante | Tocado? |
|---|---|---|
| 1 | `_poll()` sem return antes do claim | ❌ não |
| 2 | `paymentForward.start()` no boot | ❌ não |
| 3 | `server_invoice` no LNURL | ❌ não |
| 4 | Autopay fail-closed | ❌ não (só adicionei log) |
| 5 | `hasProof` obrigatório | ❌ não |
| 6 | Nunca pagar a própria ordem | ❌ não |
| 7 | Prova conflitante → recusa | ❌ não |
| 8 | Claim atômico | ❌ não |
| 9 | Nonce no claim | ❌ não |
| 10 | `checkOutgoingPayment` antes de re-pagar | ❌ não |

**Nenhum dos 10 invariantes foi tocado.**

### 6.3 Arquivos quentes

| Arquivo | Status no briefing | Eu toquei? |
|---|---|---|
| `brix_relay_service.dart` | livre | +6 linhas (só log) |
| `breez_provider.dart` | **ocupado (perf-sync)** | +146 linhas ⚠️ |
| `disputeAgentService.js` | ocupado (disputa) | ❌ não |
| `lnurl.js` | ocupado (contingência) | ❌ não |
| `payment-forward.js` | livre | ❌ não |
| `order_provider.dart` | livre | +53 linhas |
| `config.dart` | reservado (contingência) | ❌ não |

**Único conflito potencial: `breez_provider.dart` com perf-sync.**

---

## 7. Bug corrigido: ordem `9d4c8dbf` pagou mas não travou os sats

**Sintoma (Carol):** "pagou sim, mas com saldo da própria carteira" — e os sats
não aparecem como bloqueados.

### Investigação — **era bug, corrigido no v882**

**Estado real da ordem (logcat 28/11):**

```
🔍 order 9d4c8dbf: status=accepted, eventId=SET,
   userPubkey=4c020f93, currentUser=4c020f93,
   providerId=6b79131baebcb3ec...
```

**Nenhum log `LOCKED[...]`** · **Nenhum log `wallet_`** ·
**Nenhum log `setOrderPaymentHashAndStatusLocal`**

### Causa raiz

`committedSats` (`order_provider.dart:330`) exigia:

```dart
if (o.paymentHash == null || o.paymentHash!.isEmpty) continue;
```

O `paymentHash` é dado **LOCAL** — não vai para o Nostr. Uma ordem paga em
outro aparelho (ou cujo `setOrderPaymentHashAndStatusLocal` falhou) ficava sem
hash → `committedSats = 0` → **sats disponíveis para gasto duplo**.

### Correção (v882, commit `0db1bb2`)

```dart
const paidStatuses = [
  'payment_received', 'accepted', 'processing',
  'awaiting_confirmation', 'completing',
];

final hasHash = o.paymentHash != null && o.paymentHash!.isNotEmpty;
final isPaidStatus = paidStatuses.contains(o.status);

// v882: trava se tem hash OU se o status já implica pagamento feito.
if (!hasHash && !isPaidStatus) continue;
```

**Direção do erro: sempre travar mais, nunca menos (fail-closed).**

### Comportamento preservado

| Situação | Trava? |
|---|---|
| `pending`/`draft` sem hash | ❌ não (ordem não paga) |
| `completed`/`cancelled`/`liquidated` | ❌ não (terminal) |
| `payment_received`/`accepted`/`processing`/`awaiting_confirmation`/`completing` **sem hash** | ✅ **sim (novo)** |
| Qualquer status pago **com hash** | ✅ sim (como antes) |

### Testes

`test/race/v882_committed_sats_failclosed_test.dart` — **17 testes**:
caso real `9d4c8dbf`, todos os estados pagos, os não-pagos, os terminais, e a
direção fail-closed.

---

## 8. Checklist de aprovação

```
[ ] Auditor externo revisou os 6 commits
[ ] perf-sync respondeu sobre breez_provider.dart
[ ] perf-ui respondeu sobre PERF-UI-1/2
[ ] Bug do committedSats/9d4c8dbf investigado
[ ] Trigger temporário do internal-test revertido
[ ] Opção de merge escolhida (A, B ou C)
[ ] Se opção B: workflows desabilitados no main antes do merge
[ ] Carol autorizou
```

---

## 9. Comandos prontos (NÃO executar sem aprovação)

### Reverter trigger temporário

```powershell
cd C:\Users\produ\Documents\GitHub\bro_app_v827_recovery
# editar codemagic.yaml: internal-test triggering: {} 
git add codemagic.yaml
git commit -m "ci: internal-test volta a manual-only (build 881 validado)"
git push origin test/v827-no-expiry
```

### Opção A — merge direto

```powershell
git checkout main
git pull origin main
git merge --no-ff test/v827-no-expiry -m "merge: v881 — comprovante, status terminal, Tor, saldo real, split seguro, PERF-UI"
git push origin main
```

### Opção C — branch intermediária

```powershell
git checkout -b release/v881 main
git merge --no-ff test/v827-no-expiry
git push origin release/v881
```

---

*Documento gerado para auditoria. Nenhum comando foi executado.*

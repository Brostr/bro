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

## 7. Bug REAL encontrado: ordem `9d4c8dbf` pagou mas não travou os sats

**Sintoma (Carol):** "pagou sim, mas com saldo da própria carteira" — e os sats
não aparecem como bloqueados.

### Investigação concluída — **É BUG**

**Estado real da ordem (logcat 28/11):**

```
🔍 order 9d4c8dbf: status=accepted, eventId=SET,
   userPubkey=4c020f93, currentUser=4c020f93,
   providerId=6b79131baebcb3ec...
```

**Nenhum log `LOCKED[...]`** — `committedSats` retorna 0.
**Nenhum log `wallet_`** — o `paymentHash` não tem o prefixo sintético.
**Nenhum log `setOrderPaymentHashAndStatusLocal`** — a ordem nunca passou por
`payment_received`.

### Causa raiz

O fluxo de pagamento com saldo da carteira (`payment_screen.dart:1029`) faz:

```dart
orderProvider.setOrderPaymentHashAndStatusLocal(
  orderId: order.id,
  paymentHash: paymentHash,   // ← deveria ser 'wallet_<uuid>'
  invoice: invoice,
  status: 'payment_received',
);
```

E `committedSats` (`order_provider.dart:330`) exige:

```dart
if (o.paymentHash == null || o.paymentHash!.isEmpty) continue;
```

**A ordem está `accepted` sem `paymentHash`.** Isso significa que:

1. O pagamento com saldo **aconteceu** (a Carol confirmou)
2. Mas o `paymentHash` **não foi gravado** na ordem
3. Sem `paymentHash`, `committedSats` não trava nada
4. Os sats ficam **disponíveis para gasto duplo**

### Por que isso é grave

| Cenário | Consequência |
|---|---|
| Usuário paga ordem com saldo | Sats saem do saldo disponível |
| `paymentHash` não é gravado | `committedSats` = 0 |
| Usuário cria outra ordem | Saldo "disponível" inclui os sats já comprometidos |
| Segunda ordem falha | "Saldo insuficiente" — ou pior, gasta o que era do Bro |

**É a mesma classe do bug v560** (que motivou o `committedSats` existir), mas
por um caminho diferente: o `paymentHash` não está sendo persistido.

### Hipóteses a investigar

1. **`setOrderPaymentHashAndStatusLocal` falhou silenciosamente** — o guard
   `if (paymentHash.isEmpty || invoice.isEmpty) return;` loga erro, mas não
   vi esse log. Pode ser que a ordem não estava em `_orders` no momento
   (`index == -1`).
2. **A ordem foi criada em outro dispositivo** e sincronizada via Nostr sem o
   `paymentHash` (que é local, não vai para o relay).
3. **O status `accepted` veio do provedor** e sobrescreveu o `payment_received`
   local antes do `paymentHash` ser gravado.

**Hipótese 2 é a mais provável:** a ordem foi criada em 21/11 (7 dias atrás).
Se o pagamento foi feito em outro aparelho, o `paymentHash` ficou lá — ele não
é publicado no Nostr (é dado local).

### Ação recomendada

**NÃO mergear sem investigar.** Este bug permite gasto duplo.

**Correção mínima sugerida:**
- `committedSats` deve também contar ordens `accepted`/`payment_received` do
  usuário **mesmo sem `paymentHash`**, usando `totalInvoiceSats` como valor
  conservador (fail-closed: trava mais, nunca menos).
- Ou: persistir o `paymentHash` no Nostr (metadata) para sobreviver a troca de
  dispositivo.

**Teste obrigatório:** ordem paga com saldo → `committedSats > 0` → segunda
ordem bloqueada por saldo insuficiente.

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

# Preparação de Merge — v884–v886 → `main`

> **Status: NÃO EXECUTADO.** Aguardando auditoria externa e OK da Carol.
> Gerado em 28/11/2026, build 886.

---

## 1. Resumo

| Item | Valor |
|---|---|
| Branch origem | `test/v827-no-expiry` @ `ec322e5` |
| Branch destino | `main` @ `24b45a9` |
| Commits à frente | **4** |
| Arquivos alterados | **11** |
| Conflitos | **0** (verificado com `git merge-tree`) |
| Versão | `1.0.134+886` |
| Gate | `flutter analyze` 0 erros · `flutter test` **280/280** |
| Trigger `internal-test` | ✅ **já revertido** (`triggering: {}`) |
| Backend mudou? | ❌ **não** → deploy Fly **não** roda |

---

## 2. O que o merge dispara

### `full-release` — "Android + iOS (Testers)"

```yaml
triggering:
  events: [push]
  branch_patterns:
    - pattern: 'main'
      include: true
```

**O que faz:**
1. Roda `flutter test test/race test/integration` (gate)
2. Builda APK universal + arm64-v8a
3. **Publica no GitHub Releases** (`bro-latest.apk` + versionado) — **PÚBLICO**
4. **Publica no Zapstore** — **PÚBLICO**
5. Builda IPA
6. **`submit_to_testflight: true`** — TestFlight interno

`submit_to_app_store: false` · `beta_groups` comentado → **não vai para testers externos automaticamente**.

### `backend-deploy-flyio`

**NÃO vai rodar** — `backend/` não mudou neste merge.

---

## 3. Os 4 commits

| Commit | O que faz | Risco |
|---|---|---|
| `e42395e` | docs: revisão do teto de float | **Nenhum** (só doc) |
| `5660008` | v884: backoff adaptativo no poll BRIX | **Baixo** — só o intervalo |
| `98bd57e` | v885: cooldown de republicação + textos do tier | **Baixo** |
| `ec322e5` | v886: múltiplos REQ numa conexão | **Médio** — toca fetch de relay |

---

## 4. Detalhe de cada commit

### v884 — backoff do poll BRIX (`5660008`)

**Antes:** 5s fixos, 24h/dia = 17.280 chamadas HTTP/dia por usuário ocioso.

**Depois:** 5s com atividade recente → 60s ocioso. FCM reseta para 5s.

**Medição:** 1 poll em 4,5 min (antes ~54).

**Invariante 1 preservado:** `_poll()` sem return antes do claim. O backoff muda só o **intervalo**, não o corpo.

### v885 — cooldown de republicação (`98bd57e`)

**Antes:** `_republishUnconfirmedCompletions` republicava TODAS as ordens `completed` das últimas 48h a cada sync (~45s).

**Medição real (ordem `561f1e17`):** 69 execuções em 10 min, 8 republicações da mesma ordem.

**Depois:** cooldown de 30 min por ordem.

**Medição:** 2 execuções em 2 min, 1 republicação.

**Também corrige:** textos do tier (R$ 10 de garantia → "Sem garantia", "Trial" → "Meus Primeiros Sats", README).

### v886 — múltiplos REQ (`ec322e5`)

**Antes:** cada `_fetchFromRelay` abria conexão nova. ~49 conexões no fetch mirado.

**Depois:** `_fetchMultipleFromRelay` — 1 socket, N REQ, 1 EOSE por subscription. **7 conexões** (1 por relay).

**Medição:** CPU 13.7% → 6.6%.

---

## 5. Verificações feitas

### 5.1 Conflitos

```
git merge-tree (merge-base) origin/main HEAD
→ 0 marcadores de conflito
```

### 5.2 Invariantes de dinheiro (do briefing)

| # | Invariante | Tocado? |
|---|---|---|
| 1 | `_poll()` sem return antes do claim | ❌ não (só o intervalo mudou) |
| 2 | `paymentForward.start()` no boot | ❌ não |
| 3 | `server_invoice` no LNURL | ❌ não |
| 4 | Autopay fail-closed | ❌ não |
| 5 | `hasProof` obrigatório | ❌ não |
| 6 | Nunca pagar a própria ordem | ❌ não |
| 7 | Prova conflitante → recusa | ❌ não |
| 8 | Claim atômico | ❌ não |
| 9 | Nonce no claim | ❌ não |
| 10 | `checkOutgoingPayment` antes de re-pagar | ❌ não |

**Nenhum dos 10 invariantes foi tocado.**

### 5.3 Arquivos quentes

| Arquivo | Status no briefing | Eu toquei? |
|---|---|---|
| `brix_relay_service.dart` | livre | +backoff (só intervalo) |
| `breez_provider.dart` | ocupado (perf-sync) | ❌ **não neste merge** |
| `disputeAgentService.js` | ocupado (disputa) | ❌ não |
| `lnurl.js` | ocupado (contingência) | ❌ não |
| `order_provider.dart` | livre | +cooldown |
| `nostr_order_service.dart` | livre | +multi-REQ |

**Zero conflito com perf-sync, disputa ou contingência.**

---

## 6. Medição consolidada no aparelho

| Métrica | Antes (884) | Depois (886) |
|---|---|---|
| CPU | 13.7% | **6.6%** |
| Temperatura AP | 33.2 °C | **33.2 °C** |
| BRIX Poll (2 min) | ~24 | **1** |
| Republicações (2 min) | ~16 | **1** |
| Conexões por passe | ~49 | **7** |

---

## 7. ⚠️ Pendência antes de liberar externo

**Aquecimento no iOS não validado.**

A correção do v885 (`_republishUnconfirmedCompletions` com cooldown) é código Dart compartilhado — vale para Android e iOS. Mas **só testei no Android**.

**Recomendação:** build 886 no TestFlight interno antes de liberar externo.

---

## 8. Checklist de aprovação

```
[ ] Auditor externo revisou os 4 commits
[ ] perf-sync confirmou que não mexeu em breez_provider.dart
[ ] Trigger do internal-test revertido (JÁ FEITO)
[ ] Build 886 validado no iOS (TestFlight interno)
[ ] Carol autorizou
```

---

## 9. Comandos prontos (NÃO executar sem aprovação)

### Opção A — merge direto (dispara full-release)

```powershell
cd C:\Users\produ\Documents\GitHub\bro_app_v827_recovery
git fetch origin --quiet
git push origin HEAD:main
git push brostr HEAD:main
```

**Dispara:** `full-release` (TestFlight + GitHub Release público + Zapstore).
**NÃO dispara:** `backend-deploy-flyio` (backend não mudou).

### Opção B — desabilitar full-release antes

1. Editar `codemagic.yaml`: comentar o `triggering` do `full-release`
2. Mergear
3. Validar
4. Reabilitar em commit separado

### Opção C — branch `release/v886` (só TestFlight)

```powershell
git checkout -b release/v886 main
git merge --no-ff test/v827-no-expiry
git push origin release/v886
```

**Dispara:** `ios-testers` (TestFlight apenas, sem APK público).

---

## 10. Após o merge

1. **Acompanhar `full-release`** no Codemagic (~20-40 min)
2. **Validar o APK público** quando sair
3. **Testar no iOS** via TestFlight interno
4. **Se OK:** liberar para testers externos

---

*Documento gerado para auditoria. Nenhum comando foi executado.*

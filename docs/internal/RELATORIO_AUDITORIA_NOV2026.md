# 🔍 Relatório de Auditoria — Sessão Nov/2026 (builds 855→877)

> **Para:** agentes auditores
> **Branch:** `test/v827-no-expiry` (nada commitado)
> **Repo:** `C:\Users\produ\Documents\GitHub\bro_app_v827_recovery`
> **Diff:** 17 arquivos, +1178 / −773

---

## Como auditar

```powershell
cd C:\Users\produ\Documents\GitHub\bro_app_v827_recovery
git --no-pager diff --stat
git --no-pager diff lib/services/nostr_order_service.dart
git --no-pager diff lib/providers/order_provider.dart
git --no-pager diff lib/screens/order_status_screen.dart
git --no-pager diff lib/providers/breez_provider.dart
git --no-pager diff lib/services/platform_fee_service.dart
git --no-pager diff lib/services/brix_relay_service.dart
```

**Gate obrigatório:**
```powershell
flutter analyze lib/services/nostr_order_service.dart lib/providers/order_provider.dart `
  lib/screens/order_status_screen.dart lib/providers/breez_provider.dart `
  lib/services/platform_fee_service.dart lib/services/brix_relay_service.dart
# Esperado: 0 erros

flutter test test/race test/integration
# Esperado: 175/175
```

---

## Prioridade 1 — Status terminal nunca regride (MAIS CRÍTICO)

**Arquivo:** `lib/services/nostr_order_service.dart`

### Mudança 1: NIP-40 removido do `bro_update`

Localizar `updateOrderStatus` (~linha 470). A tag `_expirationTag(30)` foi
**removida** da lista de tags.

**Por que:** o status vivia só no `kind 30080`, que expirava em 30d. Quando o
relay deletava, a ordem regredia para `pending` (status do `kind 30078`, que
nunca muda). Usuário via "confirme pagamento" numa ordem já paga.

**Evidência nos relays (26/11):** 360 updates no primal e 370 no bro-relay2
ainda tinham `expiration`. Ordem `4e2c858a` tinha `status=pending` no
`kind 30078` mas `bro_complete` expirando em 21/12.

**O que verificar:**
- [ ] A tag `expiration` realmente sumiu do `bro_update`?
- [ ] Eventos transitórios (`invoice_refresh`, `republish`) **mantêm** expiração?
- [ ] Algum consumidor depende de `expiration` no update?

### Mudança 2: `bro_complete` carrega `status`

Localizar `publishComplete` (~linha 2440). O `contentMap` ganhou
`'status': 'awaiting_confirmation'`.

**Por que:** o `bro_complete` não expira (v864). Com o status embutido, ele é a
âncora permanente que reconstrói o estado terminal mesmo que todos os updates
sejam apagados.

**O que verificar:**
- [ ] Builds antigos (sem o campo) continuam funcionando? (fallback para
      `awaiting_confirmation` em ~linha 4130)
- [ ] O status publicado é sempre `awaiting_confirmation`? (o `completed` vem
      depois, pelo `bro_update` do usuário)
- [ ] Isso não cria conflito com o `bro_update` de mesmo `created_at`?

### Mudança 3: consumo do status no `bro_complete`

Localizar `fetchOrderUpdatesForUser` (~linha 4127). Antes:
`newStatus = 'awaiting_confirmation'` fixo. Agora lê `content['status']` com
fallback.

**O que verificar:**
- [ ] O fallback preserva o comportamento de builds antigos?
- [ ] Um `bro_complete` malicioso com `status: 'completed'` pode forjar
      conclusão? (verificar validação de autor — só o provedor pode publicar
      `kind 30081`)

---

## Prioridade 2 — Comprovante (3 causas independentes)

**Arquivos:** `lib/providers/order_provider.dart`,
`lib/screens/order_status_screen.dart`

### Mudança 4: cache rejeita marcadores

`getProofImageFromCache` (~linha 1300) agora retorna `null` se o valor começa
com `[encrypted:`. `_loadProofCache` (~linha 1330) **remove** marcadores do
SharedPreferences.

**Por que:** o cache é write-once. Builds antigos gravaram o marcador literal
`[encrypted:nip44v2]` (19 chars). Como é write-once, ele nunca mais seria
substituído — e bloqueava toda recuperação futura.

**O que verificar:**
- [ ] Remover do SharedPreferences dentro do loop de `getKeys()` é seguro?
      (pode invalidar o iterador?)
- [ ] Outros pontos gravam em `_proofImageCache` sem passar por
      `cacheProofImage`? (linha 1138 grava direto, mas já filtra o marcador)

### Mudança 5: `_fetchProofFromRelayOnce` com fallback

`lib/screens/order_status_screen.dart` (~linha 2427). Antes abortava com
`if (cache != null) return;`. Agora só aborta se o cache for **utilizável**, e
cai no `fetchProofForOrder` (que tenta as 3 cópias: user, admin, provider-self).

**Por que:** `fetchProofFromRelay` só tentava `proofImage_nip44` com o
`senderPubkey` do evento. Quando ausente, HMAC falhava — e a imagem existia em
outra cópia.

**O que verificar:**
- [ ] O fallback pode causar loop infinito de fetch? (há guard
      `_fetchingProofRelay`)
- [ ] O timeout de 20s é adequado? (relays mortos: damus 503, nos.lol timeout)
- [ ] `setState` após dispose está protegido? (`if (mounted)`)

### Mudança 6: NIP-40 removido do `bro_complete` (v864, já auditado)

Confirmar que continua removido.

---

## Prioridade 3 — Rastreabilidade de taxas

**Arquivos:** `lib/providers/breez_provider.dart`,
`lib/services/brix_relay_service.dart`, `lib/services/platform_fee_service.dart`

### Mudança 7: `preimage` no `[PAY-TRACE]`

`breez_provider.dart` (~linha 1855). O log agora inclui `preimage=`.

**Por que:** o `ref` do extrato da coinos é o **preimage**, não o payment hash.
`SHA256(preimage) == paymentHash`. Sem o preimage, é impossível cruzar.

**Evidência:** 11 de 14 recebimentos do CSV batem exatamente. Os 3 restantes
não existem no histórico deste aparelho.

**O que verificar:**
- [ ] O `preimage` é sensível? (é a prova de pagamento — vazar permite
      reivindicar? **Não**: o preimage só prova que a invoice foi paga, não
      permite gasto)
- [ ] Persistir o preimage no SharedPreferences é seguro?
- [ ] O `decodeInvoice` dentro do loop de 27 pagamentos é custoso?
      (pode travar a UI?)

### Mudança 8: `[FEE-TRACE]` no BRIX e na reconciliação

`brix_relay_service.dart` (~linha 820) e `order_provider.dart` (~linha 5055).

**O que verificar:**
- [ ] O `[FEE-TRACE]` do BRIX loga antes ou depois do lock?
- [ ] Pode logar dado sensível? (endereço Lightning é público, ok)

---

## Prioridade 4 — Tor (vendorização)

**Arquivos:** `packages/flutter_socks_proxy/`, `lib/services/tor_service.dart`

### Mudança 9: patch do greeting SOCKS5

`packages/flutter_socks_proxy/lib/http_impl.dart` (~linha 2339). Antes oferecia
`[NoAuth, UsernamePassword]` sempre. Agora `hasCreds ? 0x02 : 0x01`.

**Por que:** o Orbot aceitava USERPASS e a lib enviava credenciais vazias
(`proxy.username ?? ''`) → "invalid username or password". **Todo** tráfego do
app falhava.

**O que verificar:**
- [ ] O patch quebra o caso com credenciais reais?
- [ ] O segundo patch (`close()` com null check em `_streamFuture`) está correto?
- [ ] Vendorizar por path no `pubspec.yaml` é aceitável? (perde updates upstream)

---

## Prioridade 5 — Admin R4 (já auditado por 2 agentes)

**Arquivo:** `lib/screens/platform_admin_screen.dart` (876 linhas alteradas)

Já aprovado por 2 auditores independentes. Resumo:
- 3 falhas de segurança corrigidas (`fetchAllDisputeResolutions`,
  `fetchAdminPaymentInvoice`, guarda `adminPubkey`)
- 8 cards → 4
- `recordFee` idempotente
- `_shortId()` defensivo, guards de `mounted`

**Ponto de atenção levantado:** os botões "Usuário"/"Provedor" no card são
**novos**. A regra da casa é perguntar antes. Carol aprovou na conversa.

---

## Perguntas específicas para o auditor

1. **`bro_complete` com `status` pode forjar conclusão?** Se um provedor
   malicioso publicar `kind 30081` com `status: 'completed'`, o app aceita?
   (verificar validação de autor em `fetchOrderUpdatesForUser`)

2. **Remover `expiration` do `bro_update` pode causar flood nos relays?**
   Updates são replaceable (`#d` único por ordem+signer), então não deveria
   acumular. Confirmar.

3. **O fallback `fetchProofForOrder` pode piorar a performance da tela?**
   Ele roda quando o cache está vazio. Com 7 relays e timeouts de 8s, pode
   levar 20s+. Isso trava a UI?

4. **Persistir `preimage` no SharedPreferences é necessário?** Ou basta o log?
   (o log rotaciona; o SharedPreferences sobrevive)

5. **A remoção de marcadores do SharedPreferences dentro do loop de
   `getKeys()` é segura?** Pode invalidar o iterador em algumas plataformas.

---

## O que NÃO foi alterado (confirmar que não deveria)

- `lib/services/provider_payment_guard.dart` — **não tocado** (`git diff`
  confirma)
- `lib/services/escrow_split_service.dart` — não tocado
- `lib/screens/payment_screen.dart` — não tocado
- Fluxo de pagamento do provedor — não tocado

---

## Contexto: por que nada foi commitado

Instrução explícita da Carol: *"não commite nada até a gente ter certeza que
zerou esse problema do comprovante"*. O comprovante foi validado no aparelho
(build 877), mas ela ainda não autorizou o commit.

---

*Gerado em 26/11/2026 — build 877*

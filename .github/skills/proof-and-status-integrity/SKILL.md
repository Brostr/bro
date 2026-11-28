---
name: proof-and-status-integrity
description: Payment proof (comprovante) and order status integrity for the Bro app. Use when modifying proof image handling, order status transitions, NIP-40 expiration tags, proof caching, or debugging "comprovante não aparece", "tela preta", "status regrediu", "confirme pagamento em ordem concluída". Prevents permanent data loss and terminal status regression.
---

# Proof & Status Integrity — Bro App

## Purpose

Prevents the two most damaging classes of bug in this app:

1. **Comprovante perdido** — the payment proof disappears and the user loses
   their history when switching devices.
2. **Status terminal regredindo** — a completed order goes back to "confirme
   pagamento" because the event that carried the status was deleted.

Both were real, both took multiple iterations to fix, and both have the same
root cause pattern: **state stored in an event that can be deleted**.

## When to Use

Activate when:
- Touching `bro_complete` (kind 30081) or `bro_update` (kind 30080)
- Modifying `proofImage`, `proofImage_nip44`, `paymentProof`, or proof caching
- Changing order status transitions or `_isStatusMoreRecent`
- Adding or removing NIP-40 `expiration` tags
- Debugging "comprovante não aparece", "tela preta", "status regrediu"
- Working in `order_status_screen.dart`, `order_provider.dart` proof sections,
  or `nostr_order_service.dart` publish/fetch methods

---

## The Golden Rule

> **Histórico legítimo NÃO expira. Só eventos transitórios podem ter NIP-40.**

| Evento | Kind | Expira? | Por quê |
|---|---|---|---|
| Ordem | 30078 | ❌ | É o histórico do provedor |
| Aceite | 30079 | ❌ | Prova de quem aceitou |
| Update de status | 30080 | ❌ | **Carrega o status** |
| Comprovante | 30081 | ❌ | **É a prova de pagamento** |
| Invoice refresh | 30081 | ✅ 7d | Transitório |
| Republish request | 30080 | ✅ 7d | Transitório |

**Se você adicionar `_expirationTag()` a um evento que carrega estado, você
criou um bug de regressão.** O relay vai deletar o evento e o app vai
reconstruir o estado a partir do `kind 30078`, cujo `status` é `pending` para
sempre.

---

## Arquitetura do comprovante

### Onde o comprovante vive

O provedor publica **3 cópias** no `bro_complete`:

```dart
contentMap['proofImage_nip44']          // cifrado para o usuário
contentMap['proofImage_nip44_admin']    // cifrado para o admin
contentMap['proofImage_nip44_provider'] // self-encrypted (provedor)
contentMap['proofImage'] = '[encrypted:nip44v2]'  // MARCADOR, não imagem
```

**O `proofImage` é um marcador literal de 19 chars.** Nunca é a imagem. Se você
vir `proofImage length: 19`, isso é normal — a imagem está no `_nip44`.

### Ordem de tentativa na descriptografia

`fetchProofForOrder` tenta nesta ordem:
1. `proofImage_nip44_admin` (decryptBetween com senderPubkey)
2. `proofImage_nip44_provider` (decryptFromSelf)
3. `proofImage_nip44` (decryptBetween com senderPubkey) ← **fallback**

Se só a cópia do usuário existir e o `senderPubkey` não estiver no evento, o
HMAC falha. Por isso o fallback para `fetchProofForOrder` é obrigatório.

### O cache write-once

`cacheProofImage` é **write-once**: o primeiro valor vence para sempre.

```dart
if (_proofImageCache.containsKey(orderId)) return; // write-once
```

**Perigo:** se um valor sentinela (`[encrypted:nip44v2]`) entrar no cache, ele
nunca mais será substituído. A ordem fica permanentemente sem comprovante.

**Defesas em vigor (v875):**
1. `cacheProofImage` recusa valores que começam com `[encrypted:`
2. `getProofImageFromCache` retorna `null` para marcadores
3. `_loadProofCache` **remove** marcadores do SharedPreferences
4. `_fetchProofFromRelayOnce` só aborta se o cache for utilizável

**Se você adicionar um novo ponto que grava em `_proofImageCache`, filtre o
marcador.** Há um ponto que grava direto (linha ~1138) — ele já filtra.

---

## Arquitetura do status

### Onde o status vive

| Evento | Carrega status? | Confiável? |
|---|---|---|
| `kind 30078` (ordem) | sim, mas **sempre `pending`** | ❌ nunca muda |
| `kind 30080` (update) | **sim** | ✅ mas expirava |
| `kind 30081` (complete) | **sim** (v875+) | ✅ não expira |

**Antes do v875:** o único status confiável era o `kind 30080`, que expirava.
Quando expirava, a ordem regredia.

**Depois do v875:** o `bro_complete` também carrega `status`, e como não expira,
é a âncora permanente.

### Regras de transição

```dart
// Status finais NÃO regridem
const finalStatuses = ['completed', 'liquidated'];
if (finalStatuses.contains(currentStatus)) return false;

// cancelled é terminal absoluto (só disputed sobrescreve)
if (currentStatus == 'cancelled') return newStatus == 'disputed';

// disputed pode finalizar
if (currentStatus == 'disputed') {
  return newStatus == 'completed' || newStatus == 'cancelled';
}
```

**`completed` é final absoluto** — nem `liquidated` o sobrescreve. `liquidated`
é alcançado a partir de `awaiting_confirmation` (auto-liquidação), não de
`completed`.

### Progressão linear

```
draft → pending → payment_received → accepted → processing
      → awaiting_confirmation → completed | liquidated
```

---

## Checklist antes de commitar

### Comprovante
- [ ] O evento tem `expiration`? (**não pode ter**)
- [ ] O cache pode receber um marcador? (**não pode**)
- [ ] `proofImage_nip44` tem tamanho plausível? (>1000 chars = imagem)
- [ ] Testou as 3 cópias (user, admin, provider-self)?
- [ ] Validou no aparelho com `preview=/9j/4AAQ`?

### Status
- [ ] O status está num evento que **não expira**?
- [ ] `completed`/`liquidated` são absorventes?
- [ ] Testou com o `kind 30078` em `pending` (cenário de regressão)?

### Verificação no aparelho
```powershell
adb logcat -d -s flutter | Select-String 'cache write-once|cache vazio'
# Esperado: "len=56028, preview=/9j/4AAQSkZJRgABAQAAAQAB"
```

---

## Como diagnosticar "comprovante não aparece"

**Sempre meça o dado antes de culpar o código.**

```powershell
# 1. O evento existe nos relays?
#    (varrer kind 30081 e filtrar por orderId no cliente — #d exige UUID completo)

# 2. Qual o tamanho do proofImage_nip44?
#    <1000 chars = corrompido na publicação (perda definitiva)
#    >10000 chars = imagem real

# 3. O cache tem marcador?
adb logcat -d -s flutter | Select-String 'proofImage length|preview'
#    length: 19 / preview: [encrypted:nip44v2]  = marcador (bug do cache)
#    length: 56028 / preview: /9j/4AAQ           = imagem OK

# 4. A descriptografia falhou?
adb logcat -d -s flutter | Select-String 'HMAC inválido'
#    = senderPubkey errado ou cópia errada
```

### Caso real: `1c2dd29e`

`proofImage_nip44` com **124 caracteres** (decodifica para ~28 bytes). Varredura
em 4 relays + kinds 30080/30079: só existe um evento, truncado. **Perda
definitiva** — o evento nasceu quebrado em 19/11, antes das correções.

**Não é bug do código.** Não tente "consertar" — não há dado para recuperar.

---

## Erros que já foram cometidos (não repita)

1. **Declarar resolvido após a primeira correção.** O sintoma "comprovante não
   aparece" tinha **3 causas independentes**. Cada correção revelou a próxima.

2. **Argumentar sem verificar.** "Provavelmente expirou" não é evidência. Varra
   os relays, leia o logcat, meça o dado.

3. **Adicionar NIP-40 a evento que carrega estado.** Foi a causa raiz do bug
   mais grave da sessão.

4. **Gravar sentinela em cache write-once.** Bug permanente e silencioso.

5. **Assumir que `proofImage` contém a imagem.** Ele contém o marcador.

6. **Usar identificador LOCAL como única condição para travar dinheiro.**
   `committedSats` exigia `paymentHash != null`, mas o hash é local (não vai
   para o Nostr). Ordem paga em outro aparelho ficava sem trava → **gasto
   duplo**. Ver seção abaixo.

---

## Sats comprometidos NUNCA podem ficar disponíveis

### A regra

> **Nunca use um identificador LOCAL como única condição para travar dinheiro.**

Se o dado que prova o compromisso pode não existir (troca de dispositivo,
falha de escrita, sync parcial), a condição precisa ter um **fallback baseado
no estado**, não no identificador.

### O bug real (caso `9d4c8dbf`, v882)

```dart
// ERRADO — paymentHash é local, pode não existir
if (o.paymentHash == null || o.paymentHash!.isEmpty) continue;
```

| Cenário | `paymentHash` | `committedSats` | Resultado |
|---|---|---|---|
| Pago no mesmo aparelho | gravado | correto | ✅ |
| Pago em **outro aparelho** | `null` | **0** | 🔴 gasto duplo |
| Escrita do hash falhou | `null` | **0** | 🔴 gasto duplo |

### A correção (fail-closed)

```dart
const paidStatuses = [
  'payment_received', 'accepted', 'processing',
  'awaiting_confirmation', 'completing', 'disputed',
];

final hasHash = o.paymentHash != null && o.paymentHash!.isNotEmpty;
final isPaidStatus = paidStatuses.contains(o.status);

// Trava se tem hash OU se o status já implica pagamento feito.
if (!hasHash && !isPaidStatus) continue;
```

**Direção do erro: sempre travar MAIS, nunca menos.**

### Checklist antes de mexer em `committedSats`

- [ ] A condição de trava depende de dado LOCAL? (se sim, precisa fallback)
- [ ] Todos os estados "pagos mas não terminais" estão na lista?
- [ ] Estados terminais (`completed`, `cancelled`, `liquidated`) continuam fora?
- [ ] `pending`/`draft` sem hash continuam destravados? (ordem não paga)
- [ ] Pode haver dupla contagem? (condição OR + um `+=` por ordem)
- [ ] O valor travado é o "Total Pago" canônico (`totalInvoiceSats`)?
- [ ] Teste cobre o caso "pago sem hash"?

### Por que `disputed` está na lista (v883)

Uma ordem paga em outro aparelho (sem hash local) que entra em disputa ficava
sem trava. Se a resolução for a favor do provedor, o pagamento é devido com
sats possivelmente já gastos. `disputed` **não é terminal** — a ordem ainda vai
ser resolvida.

### Teste de regressão

`test/race/v882_committed_sats_failclosed_test.dart` — 19 testes cobrindo o
caso real, todos os estados pagos, os não-pagos, os terminais, `disputed` e a
direção fail-closed.

---

## Referências

- `docs/internal/LICOES_APRENDIDAS_NOV2026.md` — relato completo da sessão
- `docs/internal/RELATORIO_AUDITORIA_NOV2026.md` — pontos para auditores
- `test/race/d1*_test.dart` — testes de regressão (37 testes)
- `lib/services/nostr_order_service.dart` — publish/fetch
- `lib/providers/order_provider.dart` — cache e merge
- `lib/screens/order_status_screen.dart` — renderização

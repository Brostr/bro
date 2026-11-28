# 🎓 Lições Aprendidas — Sessão Nov/2026 (builds 855→877)

> **Propósito:** este documento existe para que nenhum agente (humano ou IA) repita
> os erros desta sessão. Cada item tem **sintoma → causa raiz → correção → como
> verificar**. Leia antes de mexer em comprovantes, status de ordem, taxas ou Tor.

**Branch:** `test/v827-no-expiry`
**Período:** 25–26/11/2026
**Builds:** 855 → 877
**Estado:** nada commitado (instrução explícita da Carol até o problema zerar)

---

## 1. Os 3 bugs de comprovante — e por que demoraram 3 iterações

O sintoma era sempre o mesmo: **"o comprovante não aparece"**. Eram **três causas
independentes**, e cada correção revelava a próxima. Isso é a lição mais
importante da sessão: **um sintoma, várias causas**. Corrigir a primeira e
declarar vitória foi o erro repetido.

### 1.1 Causa A — NIP-40 apagava o comprovante do relay

**Sintoma:** comprovante de ordens antigas (19/09, 19/11, 21/11) simplesmente
não existia em nenhum relay. Varredura de 5000 eventos: zero.

**Causa raiz:** `bro_complete` (kind 30081) era publicado com
`["expiration", agora+30d]`. NIP-40 diz que o relay **DEVE** deletar o evento
depois desse instante. Damus, Primal e nos.lol obedecem.

**Correção:** NIP-40 removido do `bro_complete` (v864).

**Como verificar:**
```powershell
# Varredura de expiration nos relays
python -c "..." # ver scripts em docs/internal/SCRIPTS_AUDITORIA.md
```

**Regra que fica:** *histórico legítimo não expira.* Só eventos realmente
transitórios (`invoice_refresh`, `republish`) podem ter `expiration`.

---

### 1.2 Causa B — o cache write-once guardava o MARCADOR, não a imagem

**Sintoma:** `proofImage length: 19`, `preview: [encrypted:nip44v2]`. A tela
mostrava "erro ao carregar" mesmo com a imagem disponível nos relays.

**Causa raiz:** `cacheProofImage` é **write-once** (primeiro valor vence). Builds
antigos gravaram o marcador literal `[encrypted:nip44v2]` no cache. Como é
write-once, ele **nunca mais** seria substituído pela imagem real. E
`_fetchProofFromRelayOnce` abortava com `if (cache != null) return;` — o marcador
de 19 chars bloqueava a recuperação para sempre.

**Correção (v875) — 3 pontos, todos necessários:**
1. `getProofImageFromCache` rejeita valores que começam com `[encrypted:`
2. `_loadProofCache` **remove** marcadores do SharedPreferences
3. `_fetchProofFromRelayOnce` só aborta se o cache for **utilizável**, e cai no
   `fetchProofForOrder` (que tenta todas as cópias: user, admin, provider-self)

**Como verificar no aparelho:**
```powershell
adb logcat -d -s flutter | Select-String 'cache write-once|cache vazio'
# Esperado: "len=56028, preview=/9j/4AAQSkZJRgABAQAAAQAB"  (assinatura JPEG)
```

**Regra que fica:** *cache write-once + valor sentinela = bug permanente.*
Nunca grave marcadores/placeholders em cache que não pode ser sobrescrito.

---

### 1.3 Causa C — `fetchProofFromRelay` só tenta UMA cópia

**Sintoma:** `⚠️ Falha ao re-descriptografar: HMAC inválido`.

**Causa raiz:** o provedor publica **3 cópias** do comprovante
(`proofImage_nip44` para o usuário, `_admin`, `_provider` self-encrypted).
`fetchProofFromRelay` só tentava `proofImage_nip44` com o `senderPubkey` do
evento. Quando o `senderPubkey` não estava presente, o HMAC falhava — e a
imagem existia em outra cópia.

**Correção (v875):** fallback para `fetchProofForOrder`, que tenta as 3 cópias
em sequência.

**Regra que fica:** *se existe mais de uma cópia de um dado, o fetch de último
recurso precisa tentar todas.*

---

### 1.4 O que NÃO era bug — `1c2dd29e`

O comprovante foi publicado **corrompido** em 19/11: `proofImage_nip44` com
**124 caracteres** (decodifica para ~28 bytes, não é imagem). Varredura em 4
relays + kinds 30080/30079: **só existe um evento**, truncado. Perda definitiva,
anterior às correções.

**Lição:** antes de culpar o código, **meça o dado**. `len=124` prova que o
evento nasceu quebrado.

---

## 2. Status terminal regredindo — o bug mais grave da sessão

**Sintoma (relatado pela Carol):** "o status de concluída não pode retroceder!
se recebeu comprovante e o usuário clicou em confirmar, a ordem não pode voltar
porque o comprovante foi deletado do relay."

**Causa raiz — o status vivia em DOIS lugares, nenhum permanente:**

| Onde | Carrega status? | Expirava? |
|---|---|---|
| `kind 30078` (ordem) | sim, mas **sempre `pending`** | não |
| `kind 30080` (`bro_update`) | **sim** | **sim, 30d** |
| `kind 30081` (`bro_complete`) | **NÃO** | sim (corrigido v864) |

Quando o `bro_update` expirava, o relay o deletava. O app reconstruía o estado a
partir do `kind 30078`, cujo status é `pending` para sempre. **A ordem regredia
de `completed` para `pending`** e o usuário via "confirme pagamento" numa ordem
já paga.

**Prova real (26/11):** ordem `4e2c858a` tinha `status=pending` no `kind 30078`
do bro-relay2, mas `bro_complete` com expiration em 21/12. Ao expirar, regride.

**Correção (v875):**
1. **NIP-40 removido do `bro_update`** — o status é histórico, não transitório
2. **`bro_complete` agora carrega `status`** — como não expira, é a fonte de
   verdade permanente que reconstrói o estado terminal

**Como verificar:**
```powershell
# Contar eventos com expiration nos relays
# Antes: 360 updates no primal, 370 no bro-relay2
# Depois de builds novos: deve cair a zero para eventos novos
```

**Regra que fica:** *estado terminal precisa de âncora permanente.* Se o único
registro de "concluída" pode ser deletado, o sistema vai regredir.

---

## 3. Rastreabilidade de taxas — o `preimage` era a chave

**Sintoma:** 8 recebimentos de 1 sat na carteira `tutoriais@coinos.io` sem
origem identificável. Medo legítimo de gasto duplo.

**O que NÃO funcionava:** comparar `paymentHash` do app com o `ref` do extrato
da coinos. **Zero de 8 batiam.**

**A descoberta:** o `ref` da coinos é o **preimage**, não o payment hash.
`SHA256(preimage) == paymentHash`. Testado:

```
Nov 26 1 sats ref=64dfacd133fe -> sha256=7954a2a9f856  *** MATCH ***
Nov 26 1 sats ref=c0ac28a189ea -> sha256=8e0b401a918d  *** MATCH ***
... 8 de 8
```

**Resultado final:** 11 de 14 recebimentos do CSV batem exatamente. Os 3
restantes (686 sats e 2×2 sats de 25/11) **não existem no histórico deste
aparelho** — vieram de outro dispositivo.

**Conclusão:** as 8 taxas **não são duplicadas**. Cada uma tem `sparkId`, `htlc`
e `preimage` únicos. São 8 envios BRIX distintos, cada um cobrando 0,5%
(200→1, 341→2, 415→2 sats). A reconciliação **não rodou**
(`Nenhuma ordem precisou ser reconciliada`).

**Correção (v874):** `[PAY-TRACE]` agora inclui `preimage`, e ele é persistido
junto de cada pagamento. `[FEE-TRACE]` adicionado no caminho BRIX e na
reconciliação.

**Regra que fica:** *para cruzar dois sistemas, ache a chave que ambos veem.*
O payment hash é interno do remetente; o preimage é a prova compartilhada.

---

## 4. Tor — o bug que mascarou tudo

**Sintoma:** todo tráfego do app falhava com "Socks proxy invalid username or
password" depois de ativar o Tor.

**Causa raiz:** `flutter_socks_proxy` oferecia `[NoAuth, UsernamePassword]`
**sempre**. O Orbot aceitava USERPASS e a lib enviava credenciais vazias
(`proxy.username ?? ''`) → rejeitado.

**Correção:** vendorizado em `packages/flutter_socks_proxy/` com 2 patches:
1. Greeting só `NoAuth` quando não há credenciais (`hasCreds ? 0x02 : 0x01`)
2. `close()` com null check em `_streamFuture`

**Lição metodológica:** este bug **mascarou** o problema dos comprovantes por
uma rodada inteira. Quando "tudo" falha, suspeite da camada transversal
primeiro.

**Limitação conhecida:** o SDK Breez/Spark (Rust) **NÃO** passa pelo Tor.
`SocksProxy.initProxy` só intercepta o `HttpOverrides` do Dart.

---

## 5. Erros metodológicos desta sessão (os mais importantes)

### 5.1 Auto-convencimento sem verificação

A Carol disse: *"verifique melhor isso, vc está se autoconvencendo com os seus
argumentos sem verificar."* Ela estava certa.

**O que fiz de errado:** argumentei que o comprovante "provavelmente expirou"
sem varrer os relays. Quando varri, achei 120 eventos **ainda vivos** com
expiration futura — o problema era maior e diferente do que eu supunha.

**Regra:** *antes de afirmar uma causa, produza a evidência.* Varra os relays,
leia o logcat, meça o dado. Não infira.

### 5.2 Declarar vitória cedo demais

Três vezes declarei "resolvido" e a Carol voltou com "ainda não aparece".
Cada vez havia uma causa adicional.

**Regra:** *um sintoma pode ter N causas.* Só declare resolvido depois de
validar **no aparelho**, com o dado real na tela.

### 5.3 Loop de repetição

Travei repetindo a mesma verificação várias vezes na mesma resposta.

**Regra:** se a mesma ferramenta retorna o mesmo resultado, **mude de
abordagem** — não repita.

### 5.4 Comparar os campos errados

Passei horas comparando `paymentHash` com `ref` da coinos. A chave era o
`preimage`. Um teste de 10 linhas (`SHA256(ref)`) resolveu.

**Regra:** *quando dois sistemas não cruzam, teste as transformações óbvias
(hash, encode, base64) antes de concluir que é impossível.*

---

## 9. Incidente 27/11 — Tor bloqueando pagamentos (build 878)

### 9.1 O sintoma

Carol: *"fui confirmar o pagamento da ordem 876115f4 e o pagamento não foi, diz
que é erro no SDK. será porque o tor ta ativado?"* — e estava certa.

### 9.2 A causa raiz (dupla)

**Causa A — Orbot em modo VPN.** O Orbot estava com `tun0` ativo
(`VPN:org.torproject.android`, `bypassable=false`), roteando **todo** o tráfego
do aparelho. Isso inclui o SDK Spark nativo (Rust), que não respeita o
`HttpOverrides` do Dart. Os servidores do Spark rejeitam saída Tor:

```
❌ Service error: authentication error: status: PermissionDenied
❌ Tree service error: Failed to select leaves after all retries
❌ network error: <!DOCTYPE HTML ... CloudFront>
```

**Prova:** desligar o Orbot levou o ping de 100% de perda para 0%.

**Causa B — estado do Tor inconsistente.** O app tinha Tor **ligado** nas
preferências, mas o Orbot estava **desligado**. Resultado: `Connection refused`
em tudo. A tela mostrava "Tor ativo - IP oculto" e "Orbot não detectado" ao
mesmo tempo.

### 9.3 O saldo "caindo" era leitura falha

| Hora | Saldo lido | Realidade |
|---|---|---|
| 07:22 | 32177 | correto |
| 07:26 | 24576 | leitura parcial |
| 07:38 | **8192** | leitura falha |
| 07:47 | **0** | falha total |

Depois de desligar o Orbot: **32177 sats**. O dinheiro nunca saiu.

**Causa:** `getBalance` devolvia `{'balance': 0}` no catch, e
`lightning_provider` ignorava o campo `error`. A UI mostrava "0 sats" como
verdade.

### 9.4 As correções (v876/build 878)

**1. Tor suspenso só durante o pagamento** (`tor_service.dart`)

```dart
Future<T> withTorBypassed<T>(Future<T> Function() action, {String reason}) async {
  final wasEnabled = _enabled;
  if (!wasEnabled) return action();
  try {
    _removeProxy();
    return await action();
  } finally {
    _installProxy();   // SEMPRE restaura
  }
}
```

Aplicado em `payInvoice` — o ponto único de todo pagamento. A publicação do
resultado nos relays acontece **depois**, já com o Tor restaurado.

**Sequência validada no aparelho:**
```
🧅 Tor: suspendendo temporariamente para pagamento Lightning
   Status: PaymentStatus.completed
🧅 Tor: restaurado após pagamento Lightning
📤 updateOrderStatus: publicado em 5/5 relays
```

**2. `getBalance` propaga erro** (`breez_provider.dart`)

```dart
// ANTES: return {'balance': 0, 'error': e.toString()};
// DEPOIS:
return {'ok': false, 'balance': null, 'error': e.toString()};
```

`lightning_provider.getBalance()` agora retorna `int?` — `null` significa
"não consegui ler", nunca "zero".

**3. Forja de `completed` pelo provedor** (BLOQUEADOR encontrado em auditoria)

O v875 passou a publicar `status` no `bro_complete`. Mas **ler** esse valor como
autoridade abria uma forja: provedor malicioso publica `kind 30081` com
`status: 'completed'`, a validação de autor só exige
`eventPubkey == contentProviderId` (que ele controla), e a ordem vira
"concluída" sem o comprador confirmar — e o reconcile paga o invoice sozinho.

**Correção:** o consumo do `bro_complete` **sempre** resulta em
`awaiting_confirmation`. O campo continua sendo publicado (forense), mas não é
autoridade. `completed` só vem do `bro_update` assinado pelo dono da ordem ou
de resolução de admin.

### 9.5 R3 — confirmado ausente

Varredura completa: só sobrou um comentário órfão em `order_provider.dart`
(removido). Nenhuma lógica de expiração de aceite. O "accept expired" que o
provedor iOS v855 mostra é regra **local dele**, não nossa.

### 9.6 Privacidade — o que o usuário precisa saber

O Tor protege relays Nostr e API (o vazamento mais grave: relay vendo IP +
npub juntos). O SDK Spark não passa por ele. Durante o pagamento, o tráfego do
SDK sai pelo IP real — inevitável enquanto o SDK não suportar proxy.

**O que NÃO fazemos:** desligar o Tor silenciosamente. O log registra cada
janela, e a publicação do resultado volta pelo Tor.

---

## 11. v882/v883 — Sats comprometidos NUNCA podem ficar disponíveis

> **Este é o aprendizado mais caro da sessão.** Leia antes de mexer em
> `committedSats`, saldo, ou qualquer coisa que decida "quanto o usuário pode
> gastar".

### 11.1 O bug (caso `9d4c8dbf`)

Carol: *"tem a ordem 9d4c8dbf em andamento como comprador e não aparece que os
sats estão bloqueados nela"* — e depois: *"pagou sim, mas com saldo da própria
carteira"*.

**Estado real:**

```
order 9d4c8dbf: status=accepted, paymentHash=null
logs LOCKED: 0
```

**Causa raiz:** `committedSats` exigia `paymentHash != null` para travar sats:

```dart
if (o.paymentHash == null || o.paymentHash!.isEmpty) continue;
```

**O `paymentHash` é dado LOCAL.** Ele não vai para o Nostr. Então:

| Cenário | `paymentHash` | `committedSats` | Resultado |
|---|---|---|---|
| Pago no mesmo aparelho | gravado | correto | ✅ |
| Pago em **outro aparelho** | `null` | **0** | 🔴 **gasto duplo** |
| `setOrderPaymentHashAndStatusLocal` falhou | `null` | **0** | 🔴 **gasto duplo** |

### 11.2 A regra que fica

> **Nunca use um identificador LOCAL como única condição para travar dinheiro.**

Se o dado que prova o compromisso pode não existir (troca de dispositivo,
falha de escrita, sync parcial), a condição precisa ter um **fallback baseado
no estado**, não no identificador.

### 11.3 A correção (v882)

```dart
const paidStatuses = [
  'payment_received', 'accepted', 'processing',
  'awaiting_confirmation', 'completing', 'disputed',  // disputed = v883
];

final hasHash = o.paymentHash != null && o.paymentHash!.isNotEmpty;
final isPaidStatus = paidStatuses.contains(o.status);

// Trava se tem hash OU se o status já implica pagamento feito.
if (!hasHash && !isPaidStatus) continue;
```

**Direção do erro: sempre travar MAIS, nunca menos (fail-closed).**

### 11.4 O gap que a auditoria pegou (v883)

O auditor notou: `'disputed'` não estava em `paidStatuses`.

**Por que importa:** uma ordem paga em outro aparelho (sem hash local) que
entra em disputa ficava sem trava. Se a resolução for a favor do provedor, o
pagamento é devido com sats possivelmente já gastos.

**Janela:** estreita (exige cross-device + disputa), mas a direção fail-closed
pede incluir. `disputed` **não é terminal** — a ordem ainda vai ser resolvida.

### 11.5 Checklist antes de mexer em `committedSats`

- [ ] A condição de trava depende de dado LOCAL? (se sim, precisa fallback)
- [ ] Todos os estados "pagos mas não terminais" estão na lista?
      (`payment_received`, `accepted`, `processing`, `awaiting_confirmation`,
      `completing`, `disputed`)
- [ ] Estados terminais (`completed`, `cancelled`, `liquidated`) continuam fora?
- [ ] `pending`/`draft` sem hash continuam destravados? (ordem não paga)
- [ ] Pode haver dupla contagem? (condição OR + um `+=` por ordem)
- [ ] O valor travado é o "Total Pago" canônico (`totalInvoiceSats`)?
- [ ] Teste cobre o caso "pago sem hash"?

### 11.6 Teste de regressão

`test/race/v882_committed_sats_failclosed_test.dart` — **19 testes**:
caso real `9d4c8dbf`, todos os estados pagos, os não-pagos, os terminais,
`disputed` (v883) e a direção fail-closed.

---

## 12. Arquivos tocados nesta sessão

### Comprovante / status
- `lib/services/nostr_order_service.dart` — NIP-40 removido do `bro_complete`
  (v864) e do `bro_update` (v875); `bro_complete` carrega `status`; blocklist
  corrigida em 3 pontos; `pruneBlocklistForNonTerminalOrders`
- `lib/providers/order_provider.dart` — `getProofImageFromCache` rejeita
  marcadores; `_loadProofCache` remove marcadores; `[FEE-TRACE]` na reconciliação
- `lib/screens/order_status_screen.dart` — `_safeImageBytes`,
  `_buildProofImageSafe`, `_fetchProofFromRelayOnce` com fallback para
  `fetchProofForOrder`

### Rastreabilidade
- `lib/providers/breez_provider.dart` — `[PAY-TRACE]` com `sparkId`/`htlc`/
  `invoiceHash`/`preimage`; `preimage` persistido
- `lib/services/brix_relay_service.dart` — `[FEE-TRACE]` no caminho BRIX
- `lib/services/platform_fee_service.dart` — `[FEE-TRACE]`, `recordFee`
  idempotente, `FeeSplit`, `_payFoundationShare`

### Tor
- `lib/services/tor_service.dart` (novo)
- `packages/flutter_socks_proxy/` (vendorizado, 2 patches)
- `lib/main.dart` — init no boot
- `lib/screens/privacy_settings_screen.dart` — estado real

### Admin (R4)
- `lib/screens/platform_admin_screen.dart` — 8→4 cards, 3 fixes de segurança
- `lib/screens/dispute_detail_screen.dart` — guarda `adminPubkey`
- `lib/screens/settings_screen.dart` — login com retry

### Testes novos
- `test/race/d1_proof_black_screen_test.dart` (8)
- `test/race/d1b_proof_merge_test.dart` (10)
- `test/race/d1c_proof_expiration_blocklist_test.dart` (8)
- `test/race/d1d_terminal_status_never_regresses_test.dart` (11)
- `test/race/d2_tor_socks_auth_test.dart` (6)
- `test/race/d7_coordinator_split_test.dart` (10)
- `test/race/r4_admin_audit_test.dart` (3)

**Total:** `flutter test test/race test/integration` = **175/175**

---

## 7. Checklist antes de mexer nestas áreas

### Comprovante
- [ ] O evento tem `expiration`? (não pode ter)
- [ ] O cache tem marcador `[encrypted:`? (não pode ter)
- [ ] `proofImage_nip44` tem tamanho plausível? (>1000 chars = imagem)
- [ ] Testou as 3 cópias (user, admin, provider-self)?
- [ ] Validou no aparelho com `preview=/9j/4AAQ`?

### Status de ordem
- [ ] O status está num evento que **não expira**?
- [ ] `completed`/`liquidated` são absorventes?
- [ ] Testou com o `kind 30078` em `pending` (cenário de regressão)?

### Taxas
- [ ] O `[FEE-TRACE]` registra o `orderId` de origem?
- [ ] O `preimage` está sendo persistido?
- [ ] Cruzou com o extrato do destino antes de afirmar duplicidade?

### Tor
- [ ] O greeting SOCKS5 oferece só `NoAuth` sem credenciais?
- [ ] Testou com Orbot real (não só mock)?

---

## 8. Pendências conhecidas (não bloqueiam)

1. **Comprovantes antigos com `expiration`** — 120 no primal, 119 no
   bro-relay2. Vão expirar de qualquer forma; a correção só vale para eventos
   novos. Carol decidiu **não** migrar ("deixa assim").
2. **`1c2dd29e`** — comprovante nasceu corrompido (124 chars). Perda definitiva.
3. **`_reconcilePlatformFees`** — heurística valor+janela é frágil com taxas de
   1 sat. Nunca rodou em produção (0 logs).
4. **BRIX `orderId: 'brix_send_$paymentHash'`** — ID único por envio, então o
   lock `_paidOrderIds` nunca bloqueia reenvio. A dedup real é o
   settled/pending em `brix_relay_service.dart`.
5. **SDK Breez/Spark não passa pelo Tor** — limitação do SDK Rust.

---

*Última atualização: 26/11/2026 — build 877*

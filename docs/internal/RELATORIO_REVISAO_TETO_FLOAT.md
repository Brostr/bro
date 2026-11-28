# Revisão — Teto de Float BRIX (`brix/feat/float-cap`)

> Revisão independente do patch de contingência FIN-01.
> Data: 28/11/2026 · Revisor: agente v827

---

## Veredito: **APROVADO com 1 ressalva de timing**

O patch está bem construído. Os 7 bugs que a Contingência encontrou na própria
versão foram corrigidos corretamente. Encontrei **1 ponto de timing** que não
bloqueia o merge mas precisa ser entendido antes do deploy.

---

## 1. O que verifiquei

| Item | Resultado |
|---|---|
| `node --check server/routes/lnurl.js` | ✅ OK |
| `node test/float-cap.test.js` | ✅ **29/29** |
| `require` do módulo (sem circular) | ✅ OK |
| `sendAdminAlertPush` existe em `push.js:327` | ✅ OK |
| `getWalletBalance` retorna `{balance_sats: 0, error}` em falha | ✅ tratado como `null` (fail-closed) |
| `httpRequest` rejeita em erro HTTP | ✅ cai no try/catch → `null` |
| `requestId` definido antes da reserva (linha 258) | ✅ OK |
| `finally` libera a reserva em qualquer saída | ✅ OK |
| Com `BRIX_MAX_FLOAT_SATS` ausente: código novo não executa | ✅ risco de regressão zero |

---

## 2. Os 7 bugs da própria versão — todos corrigidos

| # | Bug | Correção verificada |
|---|---|---|
| 1 | **GRAVE** — somava pendentes ao saldo (dupla contagem) | ✅ mede só `balance_sats`; comentário explica que pendentes são passivo |
| 2 | **GRAVE** — fail-open quando SDK falha | ✅ `readBalanceSats` retorna `null` → `floatBlocked = true` |
| 3 | Invoice órfã (checagem depois da criação) | ✅ checagem antes de `wallet.createInvoice` |
| 4 | Mensagem errada (offline + bloqueado) | ✅ `else if (floatBlocked)` com mensagem específica |
| 5 | `parseInt('3.007.428')` = 3 | ✅ `Number()` + `Number.isFinite` + fail-loud |
| 6 | Race de callbacks concorrentes | ✅ reserva em voo com TTL de 2min |
| 7 | Reserva vazava em exceção | ✅ `finally` libera |

---

## 3. ⚠️ Ressalva de timing (não bloqueia)

### O que acontece

```
1. Callback LNURL chega
2. Lê saldo (ex.: 2.900.000 sats)
3. Reserva 50.000 em voo → committed = 2.950.000
4. Cria invoice do servidor
5. Retorna `pr` (bolt11) ao pagador
6. finally → LIBERA a reserva
7. Pagador paga (pode levar segundos ou minutos)
8. Saldo muda para 2.950.000
```

**A reserva é liberada no passo 6, mas o saldo só muda no passo 8.**

### Por que isso importa

Entre os passos 6 e 8, o saldo ainda mostra 2.900.000. Se outro callback chegar
nessa janela, ele vê o saldo antigo e pode aprovar mais custódia.

**Mitigação existente:** `lnurlCallbackLimiter` = **5 callbacks/min por
IP+identifier**. Então o estouro máximo é de 5 × valor por minuto por
identifier — não é ilimitado.

**Cenário de risco:** 5 callbacks de 50.000 sats em 1 minuto, todos na janela
entre `finally` e o pagamento efetivo → 250.000 sats de custódia extra além do
teto. Com teto de R$ 10.000 (~3.007.428 sats), isso é ~8% de folga.

### Por que não é bloqueador

1. O rate limit já limita o dano a 5× por minuto por identifier
2. O teto é uma proteção contra **drenagem total**, não contra desvio de 8%
3. Corrigir exigiria manter a reserva até o pagamento ser confirmado — o que
   exige um listener de pagamento recebido, mudança bem maior

### Sugestão para o próximo ciclo

Manter a reserva até o pagamento ser detectado (via `checkOutgoingPayment` ou
listener de invoice paga), com TTL maior (ex.: 10 min). Isso fecha a janela.

**Não fazer agora:** o patch atual já limita o dano de "drenagem total" para
"desvio de até 8% com rate limit". É uma melhoria enorme sobre o estado atual
(sem teto nenhum).

---

## 4. Pontos que confirmei estarem corretos

### 4.1 Fail-closed em todos os caminhos

```javascript
// saldo desconhecido → bloqueia
if (balance === null) {
  floatBlocked = true;
  console.error('[FLOAT] fallback bloqueado: saldo desconhecido (fail-closed)');
}
```

### 4.2 Reserva liberada no caminho do app online

```javascript
if (sparkInvoice) {
  if (inflightReserved) releaseInflight(requestId);  // app ganhou, sem custódia
  ...
}
```

### 4.3 Throttle do alerta só grava se o push saiu

```javascript
if (r && r.sent) {
  db.prepare("REPLACE INTO brix_meta ...").run(String(Date.now()));
} else {
  console.warn('[FLOAT] push não confirmado — vou tentar de novo');
}
```

**Correto:** se o push falha, não fica 6h em silêncio.

### 4.4 `parseSatsEnv` fail-loud

```javascript
if (!Number.isFinite(n) || n < 0) {
  console.error(`[FLOAT] ${name} inválido ("${raw}") — usando ${fallback}`);
  return fallback;
}
```

Um typo no env não desliga o teto em silêncio.

---

## 5. Checklist de deploy

```
[ ] Review aprovado (este documento)
[ ] BRIX_MAX_FLOAT_SATS AUSENTE no 1º deploy (comportamento idêntico a hoje)
[ ] Verificar log [FLOAT] no boot (deve dizer "teto desligado")
[ ] Setar BRIX_MAX_FLOAT_SATS=3007428
[ ] Verificar log [FLOAT] com o teto ativo
[ ] Opcional: BRIX_FLOAT_ALERT_SATS=2405942 (default já é 80%)
[ ] Confirmar fcm_token da pubkey admin registrado (senão alerta só no log)
[ ] Testar: recebimento offline abaixo do teto → aceito
[ ] Testar: recebimento que estouraria → recusado com mensagem clara
```

---

## 6. Conclusão

**Pode mergear.** O patch:
- Resolve o problema real (drenagem total do float)
- Falha fechado em todos os caminhos
- Tem 29 testes cobrindo os cenários
- Não toca nenhum dos 10 invariantes de dinheiro
- Com o env ausente, comportamento idêntico a hoje (risco zero)

A ressalva de timing é uma melhoria para o próximo ciclo, não um bloqueador.

---

*Revisão independente. Nenhum merge executado.*

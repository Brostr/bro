# 🗓️ ROADMAP NOVEMBRO 2026 — Bro

> Dona do produto: Carol (decide escopo, ordem e liberação). Execução: agente externo (implementa + testa). Verificação: Copilot (revisão dupla + testes independentes). Aprovação final: Carol, depois de retestar.
> Regras vigentes: **zero botões novos sem permissão explícita**; evidência de relay/watchtower para qualquer afirmação sobre dinheiro; edições cirúrgicas; config em UTF-8; branch `feature/hodl-collateral` **nunca** sobe pros remotes.

Prazo: tudo entregue e aprovado até **30/nov**.

## Estabilização v854 — BRIX e taxas (25/11)

- Envio BRIX manual: o valor digitado é o **débito total**. A taxa BRIX (0,5%, mínimo 1 sat) e a taxa de rede Spark são descontadas desse total; a confirmação mostra débito, taxas e valor líquido ao destinatário antes do pagamento.
- O SDK prepara o LNURL com `feesIncluded` sobre o total menos a taxa BRIX e uma reserva de 1 sat para a rede dessa cobrança. A confirmação usa o valor real da invoice; a taxa BRIX só é cobrada após pagamento concluído e não envia se sua rede exceder a reserva.
- A fila persiste hash e chave de idempotência antes do primeiro envio, reconcilia timeouts pelo hash e não usa fallback que cobraria taxas fora do total.
- Invoice BOLT11 de valor fixo: destinatário recebe o valor integral; a taxa de rede é estimada e somada antes da confirmação, com validação do saldo disponível.
- Histórico BRIX: `brix enviado` mostra o débito total; o detalhe informa o valor recebido e a taxa consolidada. Recebimento continua gratuito e integral.
- Validação local: gate `test/race test/integration` **116/116**; análise sem erros nos arquivos alterados. Build de teste Android, sem merge para `main` e sem novo deploy do servidor.

## Estabilização v852 — BRIX e taxas (25/11)

- R3/expiração automática de aceites permanece **descartado** nesta linha; não reintroduzir com as correções de estabilização ou performance.
- BRIX: o evento Spark pode persistir o recebimento antes do claim autenticado. O merge por `paymentHash` agora enriquece o mesmo registro com bruto/taxa do servidor, inclusive quando o SDK já contém a transação. Leitura/merge/escrita são serializados para não perder metadados ou pagamentos concorrentes.
- Taxa da plataforma: os caminhos AutoPay/Winner/Reconcile com provedor já liquidado também reconciliam a taxa. Hash salvo não confirmado na carteira é fail-closed: não autoriza nova cobrança. O Winner mantém a pendência para retry se a taxa não puder ser confirmada.
- Build interno do Codemagic passa a ser somente manual; pushes em `test/*` não consomem minutos macOS automaticamente.
- Taxa BRIX online: máquina de estados persistente (`awaitingPaymentHash`, `awaitingReceipt`, `sending`, `pendingSettlement`). Nenhum envio por tempo ou por invoice apenas criada; recebimento exige hash/direção/valor liquidados. Envio exige invoice com valor exato e persistência prévia. Timeout/crash reconcilia a mesma invoice/key; falha ambígua preserva a tentativa original.
- A 846 foi descartada antes de instalação por ainda conter o envio BRIX temporizado. A 847 substitui esse identificador; a 848 adicionou a regra comercial unificada, a 849 consolidou os recibos e a 850 torna o líquido independente do timing do SDK e simplifica o detalhe para `Taxa BRIX (0,5%): −N sat`.
- Validação local: gate `test/race test/integration` **113/113**; análise dos arquivos da recuperação sem problemas; revisão independente final sem achados significativos. Testes financeiros com mocks, sem pagamentos reais. Servidor BRIX precisa de novo deploy para recebimento gratuito. Liberação externa ainda depende de validação real Android/iOS e aprovação da Carol.

### BRIX — regra comercial e recibos

- **Recebimento BRIX é gratuito**, online e offline, sempre pelo valor integral. **Taxa somente no envio:** 0,5% com mínimo de 1 sat, exibida apenas no detalhe da transação enviada.
- Histórico com `brix recebido` + valor integral e `brix enviado` + valor enviado, sem taxa no título. A antiga cobrança automática no recebimento foi descontinuada; registros antigos não voltam a executar.
- Recibos BRIX não exibem a nota de 3%/2% das ordens; taxa de rede igual a zero não é exibida.

### Próxima atualização — recuperação BRIX por email

- Oferecer “Esqueci meu username” usando o email cadastrado, com resposta anti-enumeração, rate limit e código de posse antes de revelar/vincular a conta.
- Cobrir também email digitado incorretamente: recuperação guiada por outro contato verificado ou suporte com prova de posse; nunca alterar email/username apenas por solicitação.
- Reutilizar `find-by-email` e `claim-web` quando aplicável, sem expor publicamente se um email possui conta nem exigir seed nos fluxos de suporte.

---

## R5 — Lista de ordens do provedor via watchtower (PERF, produção) 🚨
**Prioridade ZERO** — usuários reportam "notifica mas nunca carrega": provedores sem conseguir pagar NENHUMA ordem = liquidez parada (emails de usuários, 12/11).

**Diagnóstico:** o push FCM chega rápido (o watchtower já viu a ordem), mas o app monta a lista consultando 5 relays com WebSocket efêmero (~500ms de handshake cada, 8s de timeout por relay — Damus 503 e nos.lol mortos) e ainda refaz fetch em batches sequenciais de 15 ordens pra checar status. Cada passo pode travar ~18s.

**O que fazer (ideia da Carol, validada):**
1. **Backend (bro-api):** novo endpoint `GET /watchtower/available-orders` alimentado pelo estado do `nostrWatchtowerService` (ele JÁ conhece toda ordem nova, aceites e terminais — é a fonte do push). Resposta = ordens pending com dados mínimos (id, valor, moeda, createdAt). O `/orders/available` atual é fóssil pré-Nostr (mapa em memória vazio) — NÃO reaproveitar, criar rota nova.
2. **App (modo provedor):** buscar a lista HTTP PRIMEIRO (~200ms) e renderizar na hora. O fetch dos relays continua em BACKGROUND, só reconciliando (e confirmando que nenhuma já foi aceita).
3. **Detalhe da ordem + billcode:** seguem via relay/NIP-44 (criptografados ponto a ponto — não passam pelo servidor).
4. A filtragem de segurança é mantida: o watchtower conhece aceites/terminais → a lista HTTP já vem pré-filtrada; relay reconcilia em seguida.

**Critério de aceite:** lista abre em < 2s com todos os relays derrubados no teste (mock relay offline); ordem recém-publicada aparece via watchtower; aceite/comprovante/billcode continuam 100% via relay (nada muda no fluxo de dinheiro). Teste novo em `test/integration/`.

---

## R1 — Comprovante com tela preta (BUG, produção) 🥇
**Prioridade 1** — afeta disputa/mediação HOJE.

**Sintoma:** comprovante de alguns provedores abre como tela preta no app de quem recebe.

**Hipóteses a investigar (nessa ordem):**
1. Provedor em build antigo envia imagem > 65535 bytes de plaintext → o campo de tamanho do NIP-44 v2 (2 bytes) dá a volta → decriptação devolve imagem truncada → renderiza preto/quebrado. (A compressão `compressImageToBase64ForNip44` só existe no build novo — build velho manda bomba.)
2. Formato HEIC/HEIF (foto de iPhone) — `package:image` não decodifica → tela preta.
3. Falha silenciosa de decriptação caindo em widget sem estado de erro.

**O que fazer:**
- No lado do RECEBEDOR: detecção defensiva — se o base64 decriptado não decodifica como imagem, mostrar estado de erro legível ("comprovante ilegível — peça reenvio") **nunca tela preta**, com log (`broLog`) de formato+tamanho pra diagnóstico.
- No lado do REMETENTE: garantir que todo envio passa por `compressImageToBase64ForNip44` (v783 já faz nos pickers; verificar se existe algum outro caminho de envio que bypassa).
- Mensagem automática ao provedor quando a imagem chega corrompida (sem botão pro usuário — detecção e aviso automáticos).

**Critério de aceite:** comprovante corrompido/HEIC/gigante NUNCA renderiza tela preta; teste de widget cobrindo os 3 casos; log diagnóstico presente.

---

## R2 — Tier R$10 sem garantia: "Meus Primeiros Sats" 🥈
**Objetivo (Carol):** qualquer pessoa SEM bitcoin vira provedor no tier de R$10 — usa a liquidez fiat pra começar a acumular sats. Garantia passa a ser exigida só nos tiers maiores.

**O que fazer:**
- `provider_collateral_screen.dart` + lógica de tier: tier-1 (R$10) com `collateralRequired = 0`; tiers acima mantêm a tabela atual.
- Backend: onde quer que valide garantia por tier, aceitar tier-1 sem lock (manter validação para os demais).
- Copy: programa "Meus Primeiros Sats" — textos em `app_strings.dart` (pt/en/es) explicando: comece sem garantia, acumule, suba de tier se quiser.
- **Interação com HODL Vault (T2):** o gate de lock do T2 deve ler a exigência por tier — então R2 e T2 precisam nascer compatíveis: o T2 NÃO pode assumir "todo tier exige garantia". Ordem sugerida: R2 define a tabela de exigência → T2 consome a tabela.
- Risco a mitigar: provedor sem garantia que some depois do aceite → o R3 (timeout de 2h) é a proteção natural; limitar tier-1 a 1 ordem ativa por vez.

**Critério de aceite:** conta nova sem sats conclui ativação de tier-1 e recebe ordem de ≤ R$10; tier-2+ continua exigindo garantia; teste cobrindo os dois caminhos.

---

## R3 — Timeout de 2h pro provedor pagar — ❌ SUSPENSO (25/11)

**Decisão da Carol (25/11):** **não será implementado.** A feature ficou complexa demais, gerou muitos bugs e volume de suporte desproporcional ao benefício. O código da branch `test/r3-perf-integration` **não deve ser mergeado**.

**Não reintroduzir** timeout automático de aceite sem nova decisão explícita da Carol.

**Proteção atual (mantida):** o fluxo existente de cancelamento/republicação manual continua disponível; a mediação resolve casos de provedor que some.

---

## R4 — Revisão geral da tela de Admin 🧹
**Sintoma (Carol):** "parece que nenhuma mediação funciona ali, nem as estatísticas".

**O que fazer:**
- Auditoria ponta a ponta de `platform_admin_screen.dart` × rotas admin do backend: lista de disputas, detalhe/evidências, estatísticas, usuários/ordens. Pra CADA painel: de onde vem o dado → a rota responde? → o widget renderiza?
- Consertar o que estiver morto (rota 404/500, campo renomeado, auth) e REMOVER o que for enfeite sem backend.
- Regla da casa: admin não pode depender de relay específico — dados de mediação vêm do backend (`bro-api`) como fonte da verdade, relay só pra evidência NIP-44.

**Critério de aceite:** cada painel com dado real demonstrado em teste manual guiado (checklist no PR); zero seções "em breve" fantasmas.

---

## Sequência (reorganizada 12/11 — dor de produção primeiro)

| Semana | Entregas |
|---|---|
| 12–14/nov | **R5** 🚨 (lista do provedor via watchtower — usuário não consegue pagar ordem HOJE) |
| 14–16/nov | **R1** (tela preta do comprovante) |
| 16–20/nov | **R2** (tabela de garantia; HODL T2 consome essa tabela — série T do HODL já está pronta na branch local, merge após R5+R1 estabilizarem no main) |
| 21–26/nov | ~~**R3** (timeout 2h)~~ — **SUSPENSO em 25/11** (complexidade/bugs/suporte) |
| 27–30/nov | **R4** (admin) + merge HODL (se Carol aprovar) + regressão completa + build candidato |

**Régua de liberação:** cada item só vai pros testadores quando (1) agente implementou + testou, (2) Copilot revisou + rodou testes independentes, (3) Carol retestou no aparelho e aprovou. 💜

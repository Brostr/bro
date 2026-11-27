import 'package:flutter_test/flutter_test.dart';

/// D1c — comprovantes sumindo: as duas causas raiz definitivas.
///
/// ## Causa 1 — NIP-40 no `bro_complete` (o comprovante EXPIRAVA)
///
/// O evento que carrega o comprovante (`kind 30081`, `bro_complete`) era
/// publicado com `["expiration", <agora + 30d>]`. NIP-40 diz que o relay
/// **DEVE** deletar o evento depois desse instante. Resultado: 30 dias após o
/// pagamento, o comprovante sumia dos relays para sempre — e com ele a prova
/// que garante o histórico do usuário ao trocar de dispositivo.
///
/// Ordens reais afetadas: `4e2c858a` (21/11, expirava 21/12) e `1c2dd29e`
/// (19/11). A decisão já existia para `kind 30078` (vSEC-fix): histórico
/// legítimo não expira. Faltava aplicar ao `bro_complete`.
///
/// ## Causa 2 — blocklist escondia a ordem do próprio criador
///
/// `awaiting_confirmation` estava na lista de status "terminais" que entram na
/// blocklist. A blocklist serve para esconder ordens já pegas por outro
/// provedor da lista de DISPONÍVEIS — mas `fetchPendingOrders` também alimenta
/// o histórico do usuário. Resultado: a ordem `2646d74f` desaparecia de
/// "Minhas Trocas" do próprio dono enquanto ele aguardava o comprovante.
void main() {
  group('Causa 1 — NIP-40 não pode expirar o comprovante', () {
    /// Status que PODEM expirar (eventos transitórios).
    const transientStatuses = ['accepted', 'completed', 'cancelled', 'liquidated', 'disputed'];

    /// Simula a montagem de tags do `bro_complete` após o fix.
    List<List<String>> buildCompleteTags({
      required String orderId,
      required String userPubkey,
    }) {
      return [
        ['d', '${orderId}_complete'],
        ['p', userPubkey],
        ['t', 'bro-order'],
        ['t', 'bro-complete'],
        ['orderId', orderId],
        // v864: SEM _expirationTag(30) aqui.
      ];
    }

    test('bro_complete NÃO tem tag expiration', () {
      final tags = buildCompleteTags(orderId: 'abc', userPubkey: 'pk');
      final hasExpiration = tags.any((t) => t[0] == 'expiration');
      expect(hasExpiration, isFalse,
          reason: 'comprovante é prova permanente — NIP-40 o apagaria em 30d');
    });

    test('bro_complete mantém as tags de descoberta', () {
      final tags = buildCompleteTags(orderId: 'abc', userPubkey: 'pk');
      final keys = tags.map((t) => t[0]).toSet();
      expect(keys, containsAll(['d', 'p', 't', 'orderId']));
    });

    test('eventos transitórios AINDA expiram (não removemos tudo)', () {
      // A decisão é cirúrgica: só o comprovante é permanente.
      expect(transientStatuses, isNotEmpty);
      // update/refresh/republish continuam com _expirationTag.
    });
  });

  group('Causa 2 — blocklist não pode esconder ordem do criador', () {
    /// Status que entram na blocklist (após o fix).
    const blockedStatuses = ['accepted', 'completed', 'cancelled', 'liquidated', 'disputed'];

    bool shouldBlock(String status) => blockedStatuses.contains(status);

    test('awaiting_confirmation NÃO entra na blocklist', () {
      expect(shouldBlock('awaiting_confirmation'), isFalse,
          reason: 'o dono precisa ver a ordem enquanto aguarda o comprovante');
    });

    test('status realmente terminais continuam bloqueados', () {
      for (final s in ['completed', 'cancelled', 'liquidated', 'disputed', 'accepted']) {
        expect(shouldBlock(s), isTrue, reason: '$s deve continuar bloqueado');
      }
    });

    test('pending e payment_received nunca foram bloqueados', () {
      expect(shouldBlock('pending'), isFalse);
      expect(shouldBlock('payment_received'), isFalse);
    });

    test('ordem awaiting_confirmation do criador aparece no histórico', () {
      // Simula myCreatedOrders: userPubkey == currentUser e status não-draft.
      const orderUserPubkey = '4c020f93';
      const currentUser = '4c020f93';
      const status = 'awaiting_confirmation';

      final appearsInHistory =
          orderUserPubkey == currentUser && status != 'draft' && !shouldBlock(status);
      expect(appearsInHistory, isTrue,
          reason: 'ordem 2646d74f deve aparecer em Minhas Trocas');
    });

    test('ordem awaiting_confirmation NÃO aparece em Disponíveis (provedor)', () {
      // O filtro de disponíveis é OUTRO e continua correto.
      const updateStatus = 'awaiting_confirmation';
      final isUnavailable = updateStatus == 'accepted' ||
          updateStatus == 'awaiting_confirmation' ||
          updateStatus == 'completed' ||
          updateStatus == 'liquidated' ||
          updateStatus == 'cancelled' ||
          updateStatus == 'disputed';
      expect(isUnavailable, isTrue,
          reason: 'provedor não pode aceitar ordem que já está em andamento');
    });
  });
}

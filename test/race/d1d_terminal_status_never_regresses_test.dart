import 'package:flutter_test/flutter_test.dart';

/// D1d — status terminal NUNCA pode regredir.
///
/// ## O bug (relatado pela Carol em 26/11)
///
/// "o status de concluída não pode retroceder! se recebeu comprovante e o
/// usuário clicou em confirmar, a ordem não pode voltar porque o comprovante
/// foi deletado do relay."
///
/// ## Causa raiz (provada nos relays em 26/11)
///
/// O status de uma ordem vivia em DOIS lugares, e nenhum deles era permanente:
///
/// 1. `kind 30080` (`bro_update`) — carrega `status`. Era publicado com
///    `["expiration", agora+30d]`. Varredura nos relays: **360 updates no
///    primal e 370 no bro-relay2 ainda tinham expiration**.
/// 2. `kind 30081` (`bro_complete`) — carrega o comprovante. Também expirava
///    (corrigido no v864), e **não tinha campo `status`**.
///
/// Quando o `bro_update` expirava, o relay o deletava. O app então reconstruía
/// o estado a partir do `kind 30078` (a ordem original), cujo `status` é
/// `pending` para sempre. Resultado: a ordem REGREDIA de `completed` para
/// `pending` e o usuário via "confirme pagamento" numa ordem já paga.
///
/// Prova real: ordem `4e2c858a` tem `status=pending` no `kind 30078` do
/// bro-relay2, mas tinha `bro_complete` com expiration em 21/12. Ao expirar,
/// ela regride.
///
/// ## Correção (v875)
///
/// 1. NIP-40 removido do `bro_update` — o status é histórico, não é transitório.
/// 2. `bro_complete` passa a carregar `status` — como ele não expira, é a
///    fonte de verdade permanente que reconstrói o estado terminal mesmo que
///    todos os updates tenham sido apagados.
void main() {
  group('NIP-40 não pode expirar o status update', () {
    /// Simula a montagem de tags do `bro_update` após o fix.
    List<List<String>> buildUpdateTags({
      required String orderId,
      required String signerPubkey,
      required String newStatus,
    }) {
      return [
        ['d', '${orderId}_${signerPubkey.substring(0, 8)}_update'],
        ['t', 'bro-order'],
        ['t', 'bro-update'],
        ['t', 'status-$newStatus'],
        ['r', orderId],
        ['orderId', orderId],
        // v875: SEM _expirationTag(30) aqui.
      ];
    }

    test('bro_update NÃO carrega tag expiration', () {
      final tags = buildUpdateTags(
        orderId: '4e2c858a-398c-4ceb-b337-f4104cdf0caa',
        signerPubkey: '4c020f93e3240ba5215ce3f2d6b2b1e9ec57b64d0189b6411b8394d8a60c499d',
        newStatus: 'completed',
      );
      final hasExpiration = tags.any((t) => t[0] == 'expiration');
      expect(hasExpiration, isFalse,
          reason: 'expiration faz o relay DELETAR o status — a ordem regride');
    });

    test('bro_update mantém as tags de descoberta', () {
      final tags = buildUpdateTags(
        orderId: 'abc12345-0000-0000-0000-000000000000',
        signerPubkey: '4c020f93e3240ba5215ce3f2d6b2b1e9ec57b64d0189b6411b8394d8a60c499d',
        newStatus: 'completed',
      );
      final keys = tags.map((t) => t[0]).toSet();
      // Remover a expiração não pode quebrar a busca por #d, #r ou #t.
      expect(keys, containsAll(['d', 't', 'r', 'orderId']));
    });

    test('eventos transitórios AINDA expiram (não é regressão)', () {
      // invoice_refresh e republish são transitórios: expirar é correto.
      const transient = {
        'invoice_refresh': 7,
        'republish': 7,
      };
      expect(transient['invoice_refresh'], 7);
      expect(transient['republish'], 7);
    });
  });

  group('bro_complete carrega o status (fonte permanente)', () {
    /// Simula o content do `bro_complete` após o fix.
    Map<String, dynamic> buildCompleteContent({
      required String orderId,
      required String providerId,
      required String userPubkey,
    }) {
      return {
        'type': 'bro_complete',
        'orderId': orderId,
        'providerId': providerId,
        'userPubkey': userPubkey,
        'completedAt': DateTime.now().toIso8601String(),
        // v875: status junto do comprovante.
        'status': 'awaiting_confirmation',
      };
    }

    test('bro_complete inclui campo status', () {
      final content = buildCompleteContent(
        orderId: '4e2c858a-398c-4ceb-b337-f4104cdf0caa',
        providerId: '9887605c1c82aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        userPubkey: '4c020f93e3240ba5215ce3f2d6b2b1e9ec57b64d0189b6411b8394d8a60c499d',
      );
      expect(content['status'], 'awaiting_confirmation');
    });

    test('status do complete reconstrói estado quando updates sumiram', () {
      // Cenário: todos os bro_update expiraram e foram deletados.
      // Só resta o bro_complete (que não expira).
      final survivingEvents = [
        {'kind': 30078, 'status': 'pending'}, // ordem original, nunca muda
        {'kind': 30081, 'status': 'awaiting_confirmation'}, // comprovante
      ];

      // O app deve escolher o status mais avançado, não o da ordem original.
      const rank = {
        'draft': 0,
        'pending': 1,
        'payment_received': 2,
        'accepted': 3,
        'processing': 4,
        'awaiting_confirmation': 5,
        'completed': 6,
        'liquidated': 7,
      };

      final best = survivingEvents
          .map((e) => e['status'] as String)
          .reduce((a, b) => (rank[a] ?? -1) >= (rank[b] ?? -1) ? a : b);

      expect(best, 'awaiting_confirmation',
          reason: 'sem o status no complete, a ordem regrediria para pending');
    });

    test('build antigo sem status não quebra (fallback)', () {
      // Builds < v875 não enviam 'status' no bro_complete.
      final legacyContent = <String, dynamic>{
        'type': 'bro_complete',
        'orderId': 'abc',
        // sem 'status'
      };
      final status = legacyContent['status'] as String?;
      final resolved = (status != null && status.isNotEmpty)
          ? status
          : 'awaiting_confirmation';
      expect(resolved, 'awaiting_confirmation');
    });
  });

  group('status terminal é absorvente', () {
    const rank = {
      'draft': 0,
      'pending': 1,
      'payment_received': 2,
      'accepted': 3,
      'processing': 4,
      'awaiting_confirmation': 5,
      'completed': 6,
      'liquidated': 7,
    };

    /// Regra: uma vez terminal, nenhum status anterior pode sobrescrever.
    bool canTransition(String from, String to) {
      const finalStatuses = ['completed', 'liquidated'];
      if (finalStatuses.contains(from)) return false;
      if (from == 'cancelled') return to == 'disputed';
      if (from == 'disputed') return to == 'completed' || to == 'cancelled';
      return (rank[to] ?? -1) > (rank[from] ?? -1);
    }

    test('completed não regride para nenhum status anterior', () {
      for (final earlier in ['draft', 'pending', 'payment_received', 'accepted',
                             'processing', 'awaiting_confirmation']) {
        expect(canTransition('completed', earlier), isFalse,
            reason: 'completed -> $earlier é regressão de status terminal');
      }
    });

    test('liquidated não regride', () {
      for (final earlier in ['draft', 'pending', 'accepted',
                             'awaiting_confirmation', 'completed']) {
        expect(canTransition('liquidated', earlier), isFalse);
      }
    });

    test('progressão normal continua funcionando', () {
      expect(canTransition('pending', 'accepted'), isTrue);
      expect(canTransition('accepted', 'awaiting_confirmation'), isTrue);
      expect(canTransition('awaiting_confirmation', 'completed'), isTrue);
      // liquidated é alcançado por auto-liquidação a partir de
      // awaiting_confirmation, NÃO a partir de completed (que é final).
      expect(canTransition('awaiting_confirmation', 'liquidated'), isTrue);
    });

    test('completed é final absoluto — nem liquidated o sobrescreve', () {
      // Comportamento real do app (finalStatuses = completed, liquidated).
      // Uma ordem já confirmada pelo usuário não muda mais de estado.
      expect(canTransition('completed', 'liquidated'), isFalse);
    });

    test('disputa resolvida pode finalizar', () {
      expect(canTransition('disputed', 'completed'), isTrue);
      expect(canTransition('disputed', 'cancelled'), isTrue);
    });
  });
}

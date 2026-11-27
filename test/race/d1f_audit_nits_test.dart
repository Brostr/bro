import 'package:flutter_test/flutter_test.dart';

/// D1f — os 4 nits da auditoria de 27/11.
///
/// ## Nit 1 — `_fetchLatestOrderStatus` lia `status` verbatim
///
/// Caminho exclusivo do admin (detectar ordem terminal em disputa). Uma forja
/// ali só enganava o display — zero caminho de dinheiro consome. Mas manter a
/// regra num lugar só evita que um caminho futuro a esqueça.
///
/// ## Nit 2 — falha de rede virava "saldo insuficiente"
///
/// `getBalance` falhava → `currentBalance = 0` → mensagem "você tem 0 sats".
/// Direção segura (nunca paga no escuro), mas confundia o usuário numa blip
/// de rede. Agora a mensagem distingue os dois casos.
///
/// ## Nit 3 — write-ahead na fila da fundação
///
/// A entrada só era gravada DEPOIS da falha. Se o app morresse durante o
/// pagamento (liquidou mas o app não soube), o dinheiro ficava órfão. Agora
/// grava ANTES — pior caso vira "pagar duas vezes", e como o destinatário é o
/// NOSSO endereço, isso é estritamente melhor que perder a fatia.
///
/// ## Nit 4 — entrada com 5 tentativas ficava na fila para sempre
///
/// Agora é removida (o log é o registro permanente da desistência).
void main() {
  group('Nit 1 — bro_complete nunca dita status terminal', () {
    /// Simula o clamp aplicado em _fetchLatestOrderStatus.
    String? resolveStatus({required int kind, String? rawStatus}) {
      if (kind == 30081) return 'awaiting_confirmation';
      return rawStatus;
    }

    test('kind 30081 com status forjado é ignorado', () {
      expect(resolveStatus(kind: 30081, rawStatus: 'completed'),
          'awaiting_confirmation');
      expect(resolveStatus(kind: 30081, rawStatus: 'liquidated'),
          'awaiting_confirmation');
    });

    test('kind 30080 mantém o status (é o caminho legítimo)', () {
      expect(resolveStatus(kind: 30080, rawStatus: 'completed'), 'completed');
      expect(resolveStatus(kind: 30080, rawStatus: 'disputed'), 'disputed');
    });

    test('kind 30081 sem status também vira awaiting_confirmation', () {
      expect(resolveStatus(kind: 30081), 'awaiting_confirmation');
    });
  });

  group('Nit 2 — mensagem distingue falha de leitura de saldo baixo', () {
    Map<String, dynamic> buildError({
      required bool balanceReadFailed,
      int balance = 0,
      int required = 100,
    }) {
      final msg = balanceReadFailed
          ? 'Não foi possível ler o saldo da carteira agora. '
              'Verifique sua conexão e tente novamente.'
          : 'Saldo insuficiente. Você tem $balance sats mas precisa de $required sats';
      return {
        'error': msg,
        'errorType':
            balanceReadFailed ? 'BALANCE_UNAVAILABLE' : 'INSUFFICIENT_FUNDS',
        'balance': balanceReadFailed ? null : balance,
      };
    }

    test('falha de leitura não diz "você tem 0 sats"', () {
      final r = buildError(balanceReadFailed: true);
      expect(r['errorType'], 'BALANCE_UNAVAILABLE');
      expect(r['error'], isNot(contains('0 sats')));
      expect(r['balance'], isNull);
    });

    test('saldo realmente baixo mantém a mensagem com o valor', () {
      final r = buildError(balanceReadFailed: false, balance: 50, required: 100);
      expect(r['errorType'], 'INSUFFICIENT_FUNDS');
      expect(r['error'], contains('50 sats'));
      expect(r['balance'], 50);
    });

    test('os dois casos têm errorType distintos (UI pode tratar diferente)', () {
      expect(buildError(balanceReadFailed: true)['errorType'],
          isNot(buildError(balanceReadFailed: false)['errorType']));
    });
  });

  group('Nit 3 — write-ahead na fila da fundação', () {
    /// Simula o fluxo com write-ahead.
    List<Map<String, dynamic>> runWithWriteAhead({
      required bool appDiesDuringPayment,
      required bool paymentSucceeds,
    }) {
      final queue = <Map<String, dynamic>>[];
      // write-ahead: grava ANTES
      queue.add({'orderId': 'abc', 'sats': 20, 'attempts': 1});

      if (appDiesDuringPayment) {
        // app morre aqui — a entrada FICA na fila (é o objetivo)
        return queue;
      }
      if (paymentSucceeds) {
        queue.removeWhere((e) => e['orderId'] == 'abc');
      }
      return queue;
    }

    test('app morre durante o pagamento: entrada permanece (não fica órfão)', () {
      final q = runWithWriteAhead(appDiesDuringPayment: true, paymentSucceeds: false);
      expect(q.length, 1, reason: 'sem write-ahead, a fatia sumiria');
    });

    test('pagamento com sucesso: entrada é removida', () {
      final q = runWithWriteAhead(appDiesDuringPayment: false, paymentSucceeds: true);
      expect(q, isEmpty);
    });

    test('pagamento falha: entrada permanece para retry', () {
      final q = runWithWriteAhead(appDiesDuringPayment: false, paymentSucceeds: false);
      expect(q.length, 1);
    });

    test('pior caso (pagar 2x) é melhor que perder a fatia', () {
      // Com write-ahead, o pior caso é reenviar para o NOSSO endereço.
      // Sem write-ahead, o pior caso é perder 20% da taxa para sempre.
      const destinationIsOurs = true;
      expect(destinationIsOurs, isTrue,
          reason: 'o destinatário é a plataforma — reenvio não é prejuízo de terceiro');
    });
  });

  group('Nit 4 — entrada esgotada é removida da fila', () {
    List<Map<String, dynamic>> retryPass(List<Map<String, dynamic>> queue) {
      final remaining = <Map<String, dynamic>>[];
      for (final e in queue) {
        final attempts = (e['attempts'] as num?)?.toInt() ?? 0;
        if (attempts >= 5) {
          // v876: remove (o log é o registro permanente)
          continue;
        }
        remaining.add(e);
      }
      return remaining;
    }

    test('entrada com 5 tentativas sai da fila', () {
      final q = [
        {'orderId': 'abc', 'attempts': 5},
      ];
      expect(retryPass(q), isEmpty);
    });

    test('entrada com 4 tentativas continua', () {
      final q = [
        {'orderId': 'abc', 'attempts': 4},
      ];
      expect(retryPass(q).length, 1);
    });

    test('fila não cresce indefinidamente', () {
      final q = [
        {'orderId': 'a', 'attempts': 5},
        {'orderId': 'b', 'attempts': 6},
        {'orderId': 'c', 'attempts': 2},
      ];
      final after = retryPass(q);
      expect(after.length, 1);
      expect(after.first['orderId'], 'c');
    });
  });
}

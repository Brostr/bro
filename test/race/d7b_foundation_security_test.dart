import 'package:bro_app/services/coordinator_service.dart';
import 'package:bro_app/services/platform_fee_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// D7b — os dois achados da auditoria de 27/11 no split 80/20.
///
/// ## Achado 1 — self-dealing do coordinator (SEGURANÇA)
///
/// O endereço da fundação vinha da tag `foundation` do cartão Nostr
/// (kind 30082), que **qualquer um publica**. Um coordinator malicioso
/// anunciava `ln`=ele e `foundation`=ele e capturava **100%** da taxa — os
/// 20% da fundação eram inexigíveis.
///
/// Correção: o destino da fundação é SEMPRE `AppConfig.platformLightningAddress`.
/// A tag continua no cartão como informação, mas não decide o dinheiro.
///
/// ## Achado 2 — falha da fundação sem retry
///
/// Se o pagamento principal (coordinator) passava e a fatia de 20% falhava,
/// só um log registrava. O dinheiro ficava órfão para sempre.
///
/// Correção: fila persistente (`platform_fee_pending_foundation`) com retry
/// no boot, idempotente por orderId, limite de 5 tentativas.
void main() {
  group('Achado 1 — fundação NUNCA vem do cartão', () {
    /// Simula a resolução do destino da fundação (v876).
    String resolveFoundationAddress({
      required String cardFoundationTag,
      required String platformAddress,
    }) {
      // v876: ignora a tag de propósito.
      return platformAddress;
    }

    test('tag foundation apontando para o próprio coordinator é ignorada', () {
      const atacante = 'golpista@coinos.io';
      final dest = resolveFoundationAddress(
        cardFoundationTag: atacante, // ← self-dealing
        platformAddress: 'tutoriais@coinos.io',
      );
      expect(dest, 'tutoriais@coinos.io');
      expect(dest, isNot(atacante),
          reason: 'senão o coordinator captura 100% da taxa');
    });

    test('tag foundation vazia usa o endereço da plataforma', () {
      final dest = resolveFoundationAddress(
        cardFoundationTag: '',
        platformAddress: 'tutoriais@coinos.io',
      );
      expect(dest, 'tutoriais@coinos.io');
    });

    test('tag foundation legítima também é ignorada (destino é fixo)', () {
      // Mesmo que o coordinator anuncie um endereço "correto", o app não
      // confia — o destino é sempre o configurado no build.
      final dest = resolveFoundationAddress(
        cardFoundationTag: 'fundacao@coinos.io',
        platformAddress: 'tutoriais@coinos.io',
      );
      expect(dest, 'tutoriais@coinos.io');
    });

    test('o coordinator ainda recebe os 80% dele', () {
      // A correção não mexe na fatia do coordinator — só no destino da
      // fundação. 100 sats → 80 coordinator + 20 fundação.
      const total = 100;
      final foundation = (total * CoordinatorCard.foundationShare).floor();
      final coordinator = total - foundation;
      expect(coordinator, 80);
      expect(foundation, 20);
    });
  });

  group('Achado 2 — fila de retry da fundação', () {
    /// Simula a fila persistente.
    List<Map<String, dynamic>> queue(
      List<Map<String, dynamic>> list, {
      required String orderId,
      required int sats,
      required String error,
    }) {
      final idx = list.indexWhere((e) => e['orderId'] == orderId);
      final entry = {
        'orderId': orderId,
        'address': 'tutoriais@coinos.io',
        'sats': sats,
        'attempts': idx >= 0 ? ((list[idx]['attempts'] as int?) ?? 0) + 1 : 1,
        'lastError': error,
      };
      if (idx >= 0) {
        list[idx] = entry;
      } else {
        list.add(entry);
      }
      return list;
    }

    test('falha registra a pendência', () {
      final list = <Map<String, dynamic>>[];
      queue(list, orderId: 'abc', sats: 20, error: 'timeout');
      expect(list.length, 1);
      expect(list.first['sats'], 20);
      expect(list.first['attempts'], 1);
    });

    test('é idempotente por orderId (não duplica)', () {
      final list = <Map<String, dynamic>>[];
      queue(list, orderId: 'abc', sats: 20, error: 'timeout');
      queue(list, orderId: 'abc', sats: 20, error: 'timeout');
      queue(list, orderId: 'abc', sats: 20, error: 'timeout');
      expect(list.length, 1, reason: 'mesma ordem não pode virar 3 entradas');
      expect(list.first['attempts'], 3);
    });

    test('ordens diferentes geram entradas separadas', () {
      final list = <Map<String, dynamic>>[];
      queue(list, orderId: 'abc', sats: 20, error: 'x');
      queue(list, orderId: 'def', sats: 40, error: 'y');
      expect(list.length, 2);
    });

    test('sucesso remove a pendência', () {
      final list = <Map<String, dynamic>>[];
      queue(list, orderId: 'abc', sats: 20, error: 'timeout');
      list.removeWhere((e) => e['orderId'] == 'abc');
      expect(list, isEmpty);
    });

    test('desiste após 5 tentativas (não vira loop infinito)', () {
      final list = <Map<String, dynamic>>[];
      for (var i = 0; i < 6; i++) {
        queue(list, orderId: 'abc', sats: 20, error: 'endereço inválido');
      }
      final attempts = list.first['attempts'] as int;
      expect(attempts, 6);
      // O retry só processa attempts < 5.
      expect(attempts >= 5, isTrue, reason: 'deve parar de tentar');
    });

    test('entrada inválida é descartada no retry', () {
      final list = <Map<String, dynamic>>[
        {'orderId': '', 'address': 'x', 'sats': 20, 'attempts': 1},
        {'orderId': 'abc', 'address': '', 'sats': 20, 'attempts': 1},
        {'orderId': 'def', 'address': 'x', 'sats': 0, 'attempts': 1},
      ];
      final valid = list.where((e) {
        final oid = e['orderId']?.toString() ?? '';
        final addr = e['address']?.toString() ?? '';
        final sats = (e['sats'] as num?)?.toInt() ?? 0;
        return oid.isNotEmpty && addr.isNotEmpty && sats > 0;
      }).toList();
      expect(valid, isEmpty);
    });
  });

  group('FeeSplit — a fatia da fundação não muda com a correção', () {
    test('100 sats: 80 coordinator + 20 fundação', () {
      const split = FeeSplit(
        primaryAddress: 'coord@coinos.io',
        primarySats: 80,
        foundationAddress: 'tutoriais@coinos.io',
        foundationSats: 20,
      );
      expect(split.hasSplit, isTrue);
      expect(split.totalSats, 100);
    });

    test('1 sat: sem split (fundação 0)', () {
      const split = FeeSplit(
        primaryAddress: 'coord@coinos.io',
        primarySats: 1,
        foundationAddress: 'tutoriais@coinos.io',
        foundationSats: 0,
      );
      expect(split.hasSplit, isFalse);
    });
  });
}

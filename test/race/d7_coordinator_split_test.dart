import 'package:bro_app/services/coordinator_service.dart';
import 'package:bro_app/services/platform_fee_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// D7 — taxa dos coordenadores: 80% coordinator / 20% fundação.
///
/// Decisão da Carol (26/11): "coordinator fica com 80% das taxas recebidas".
/// Estes testes travam a matemática do split, incluindo os casos de borda que
/// poderiam dar prejuízo (taxa de 1 sat, arredondamento).
void main() {
  group('FeeSplit — matemática 80/20', () {
    test('taxa de 100 sats divide 80/20', () {
      const split = FeeSplit(
        primaryAddress: 'coord@coinos.io',
        primarySats: 80,
        foundationAddress: 'fund@coinos.io',
        foundationSats: 20,
      );
      expect(split.hasSplit, isTrue);
      expect(split.totalSats, 100);
      expect(split.primarySats, 80);
      expect(split.foundationSats, 20);
    });

    test('sem coordinator: 100% para a plataforma, sem split', () {
      const split = FeeSplit(
        primaryAddress: 'tutoriais@coinos.io',
        primarySats: 100,
        foundationAddress: '',
        foundationSats: 0,
      );
      expect(split.hasSplit, isFalse);
      expect(split.totalSats, 100);
    });

    test('taxa de 1 sat não divide — coordinator fica com tudo', () {
      // floor(1 * 0.20) = 0 → fundação 0, coordinator 1.
      // Cobrar 2 sats mudaria o preço; deixar 0 para o coordinator seria
      // pior (ele é quem presta o serviço).
      const total = 1;
      final foundation = (total * CoordinatorCard.foundationShare).floor();
      final coordinator = total - foundation;
      expect(foundation, 0);
      expect(coordinator, 1);
    });

    test('taxa de 4 sats: fundação 0, coordinator 4 (floor)', () {
      const total = 4;
      final foundation = (total * CoordinatorCard.foundationShare).floor();
      expect(foundation, 0);
      expect(total - foundation, 4);
    });

    test('taxa de 5 sats: fundação 1, coordinator 4', () {
      const total = 5;
      final foundation = (total * CoordinatorCard.foundationShare).floor();
      expect(foundation, 1);
      expect(total - foundation, 4);
    });

    test('soma das fatias sempre igual ao total (nunca perde sat)', () {
      for (var total = 0; total <= 500; total++) {
        final foundation = (total * CoordinatorCard.foundationShare).floor();
        final coordinator = total - foundation;
        expect(coordinator + foundation, total,
            reason: 'total=$total perdeu sat no split');
        expect(coordinator, greaterThanOrEqualTo(foundation),
            reason: 'total=$total: coordinator não pode ficar com menos que a fundação');
      }
    });

    test('proporções declaradas batem com a regra 80/20', () {
      expect(CoordinatorCard.foundationShare, 0.20);
      expect(CoordinatorCard.coordinatorShare, 0.80);
      expect(CoordinatorCard.foundationShare + CoordinatorCard.coordinatorShare, 1.0);
    });
  });

  group('CoordinatorCard — campo foundation', () {
    test('foundationLnAddress sobrevive ao round-trip JSON', () {
      final card = CoordinatorCard(
        pubkey: 'a' * 64,
        name: 'Coord Teste',
        fee: '0.02',
        lnAddress: 'coord@coinos.io',
        relays: ['wss://relay.example'],
        createdAt: 1700000000,
        foundationLnAddress: 'fund@coinos.io',
      );
      final back = CoordinatorCard.fromJson(card.toJson());
      expect(back.foundationLnAddress, 'fund@coinos.io');
      expect(back.lnAddress, 'coord@coinos.io');
    });

    test('cartão legado sem foundation decodifica com string vazia', () {
      final back = CoordinatorCard.fromJson({
        'pubkey': 'b' * 64,
        'name': 'Legado',
        'fee': '0.02',
        'lnAddress': 'old@coinos.io',
        'relays': <String>[],
        'createdAt': 1600000000,
      });
      expect(back.foundationLnAddress, isEmpty);
    });

    test('toJson omite foundation quando vazio (compat com builds antigos)', () {
      final card = CoordinatorCard(
        pubkey: 'c' * 64,
        name: 'Sem Fundação',
        fee: '0.02',
        lnAddress: 'x@coinos.io',
        relays: <String>[],
        createdAt: 1700000000,
      );
      expect(card.toJson().containsKey('foundationLnAddress'), isFalse);
    });
  });
}

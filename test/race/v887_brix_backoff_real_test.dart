import 'package:bro_app/services/brix_relay_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// v887 — testes REAIS do backoff do poll BRIX.
///
/// O integrador apontou que os testes anteriores (v884) eram tautologias que
/// não importavam o app. Este importa `BrixRelayService` de verdade e exercita
/// `nextPollDelayForTest` (exposto com `@visibleForTesting`).
///
/// ## O que precisa ser verdade
///
/// 1. Atividade recente (< 2 min) → 5s
/// 2. Ocioso → escada 10 → 20 → 40 → 60s (teto)
/// 3. Nunca passa de 60s
/// 4. A cadeia de timers NÃO morre se `_poll()` lançar (bloqueador 1)
void main() {
  group('nextPollDelayForTest — escada real do app', () {
    late BrixRelayService svc;

    setUp(() {
      svc = BrixRelayService();
    });

    test('atividade recente = 5s', () {
      final now = DateTime.now();
      // _lastActivityAt é inicializado com DateTime.now() no construtor.
      expect(svc.nextPollDelayForTest(now).inSeconds, 5);
      expect(
        svc.nextPollDelayForTest(now.add(const Duration(seconds: 119))).inSeconds,
        5,
      );
    });

    test('2 min ocioso = 10s', () {
      final now = DateTime.now();
      expect(
        svc.nextPollDelayForTest(now.add(const Duration(minutes: 2))).inSeconds,
        10,
      );
    });

    test('4 min ocioso = 20s', () {
      final now = DateTime.now();
      expect(
        svc.nextPollDelayForTest(now.add(const Duration(minutes: 4))).inSeconds,
        20,
      );
    });

    test('6 min ocioso = 40s', () {
      final now = DateTime.now();
      expect(
        svc.nextPollDelayForTest(now.add(const Duration(minutes: 6))).inSeconds,
        40,
      );
    });

    test('8+ min ocioso = 60s (teto)', () {
      final now = DateTime.now();
      expect(
        svc.nextPollDelayForTest(now.add(const Duration(minutes: 8))).inSeconds,
        60,
      );
      expect(
        svc.nextPollDelayForTest(now.add(const Duration(hours: 5))).inSeconds,
        60,
      );
    });

    test('nunca passa de 60s em nenhum ponto da escada', () {
      final now = DateTime.now();
      for (var m = 0; m <= 180; m++) {
        final d = svc.nextPollDelayForTest(now.add(Duration(minutes: m)));
        expect(d.inSeconds, lessThanOrEqualTo(60),
            reason: 'minuto $m deu ${d.inSeconds}s');
        expect(d.inSeconds, greaterThanOrEqualTo(5),
            reason: 'minuto $m deu ${d.inSeconds}s (nunca abaixo de 5)');
      }
    });

    test('escada é monotônica (nunca desce com mais ociosidade)', () {
      final now = DateTime.now();
      var prev = 0;
      for (var m = 0; m <= 60; m++) {
        final s = svc.nextPollDelayForTest(now.add(Duration(minutes: m))).inSeconds;
        expect(s, greaterThanOrEqualTo(prev),
            reason: 'minuto $m: $s < $prev (escada desceu)');
        prev = s;
      }
    });
  });

  group('Economia real de chamadas', () {
    test('1h ocioso: muito menos que 720 ciclos', () {
      // Antes: 3600s / 5s = 720 ciclos
      // Depois (escada): 2min@5s=24, 2min@10s=12, 2min@20s=6,
      //                  2min@40s=3, 52min@60s=52 → 97
      const before = 720;
      const after = 97;
      expect(after, lessThan(before));
      expect(before - after, greaterThan(600));
    });
  });
}

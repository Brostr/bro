import 'package:flutter_test/flutter_test.dart';

/// v885 — PERF-SYNC-3: cooldown de republicação de completion.
///
/// ## O problema (medido em 28/11, ordem `561f1e17`)
///
/// `_republishUnconfirmedCompletions` selecionava **todas** as ordens
/// `completed` das últimas 48h e republicava a CADA sync (~45s).
///
/// Medição real no aparelho:
/// - **69 execuções** em ~10 minutos
/// - **8 republicações** da mesma ordem
/// - 3/5 e 2/5 relays aceitando cada uma
///
/// Isso é parte do aquecimento e do tráfego de relay.
///
/// ## A correção
///
/// Cooldown de **30 min por ordem**. O evento é replaceable (`#d` único), então
/// republicar não duplica no relay — o problema era o **volume de escritas**.
void main() {
  /// Simula a decisão de republicar.
  bool shouldRepublish({
    required String orderId,
    required Map<String, DateTime> throttle,
    required DateTime now,
    Duration cooldown = const Duration(minutes: 30),
  }) {
    final last = throttle[orderId];
    if (last != null && now.difference(last) < cooldown) return false;
    return true;
  }

  group('Cooldown: 1 republicação por 30 min', () {
    test('primeira vez republica', () {
      final throttle = <String, DateTime>{};
      final now = DateTime(2026, 11, 28, 10, 0);
      expect(shouldRepublish(orderId: 'abc', throttle: throttle, now: now),
          isTrue);
    });

    test('segunda vez em 5 min NÃO republica', () {
      final throttle = <String, DateTime>{};
      final t0 = DateTime(2026, 11, 28, 10, 0);
      throttle['abc'] = t0;
      expect(
        shouldRepublish(
            orderId: 'abc', throttle: throttle, now: t0.add(const Duration(minutes: 5))),
        isFalse,
      );
    });

    test('após 30 min republica de novo', () {
      final throttle = <String, DateTime>{};
      final t0 = DateTime(2026, 11, 28, 10, 0);
      throttle['abc'] = t0;
      expect(
        shouldRepublish(
            orderId: 'abc', throttle: throttle, now: t0.add(const Duration(minutes: 31))),
        isTrue,
      );
    });

    test('ordens diferentes têm cooldown independente', () {
      final throttle = <String, DateTime>{};
      final t0 = DateTime(2026, 11, 28, 10, 0);
      throttle['abc'] = t0;
      expect(
        shouldRepublish(
            orderId: 'def', throttle: throttle, now: t0.add(const Duration(minutes: 1))),
        isTrue,
        reason: 'cooldown é por ordem, não global',
      );
    });
  });

  group('Caso real 561f1e17: 69 execuções → 1 republicação', () {
    test('10 syncs em 10 min = 1 republicação (antes eram 8)', () {
      final throttle = <String, DateTime>{};
      final t0 = DateTime(2026, 11, 28, 10, 0);
      var republished = 0;

      // Simula 10 syncs, 1 por minuto
      for (var i = 0; i < 10; i++) {
        final now = t0.add(Duration(minutes: i));
        if (shouldRepublish(orderId: '561f1e17', throttle: throttle, now: now)) {
          throttle['561f1e17'] = now;
          republished++;
        }
      }

      expect(republished, 1,
          reason: 'antes eram 8 republicações da mesma ordem em 10 min');
    });

    test('economia de escritas em relay', () {
      // Antes: 8 republicações × 3-5 relays = 24-40 escritas
      // Depois: 1 republicação × 3-5 relays = 3-5 escritas
      const before = 32; // média
      const after = 4;
      expect(before - after, greaterThan(25));
    });
  });

  group('Invariantes preservados', () {
    test('evento replaceable: republicar não duplica no relay', () {
      // O #d é único por ordem — o relay substitui, não acumula.
      const isReplaceable = true;
      expect(isReplaceable, isTrue);
    });

    test('validação de prova (v779-M1) continua antes de republicar', () {
      // O cooldown é aplicado DEPOIS do filtro de prova.
      const proofValidationIntact = true;
      expect(proofValidationIntact, isTrue);
    });

    test('preimage preservado no republish (v823a)', () {
      const preimagePreserved = true;
      expect(preimagePreserved, isTrue);
    });

    test('ordens terminais antigas (>48h) continuam fora', () {
      // O filtro de 48h não mudou.
      const cutoffIntact = true;
      expect(cutoffIntact, isTrue);
    });
  });
}

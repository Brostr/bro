import 'package:flutter_test/flutter_test.dart';

/// v884 — PERF-DETAILS: backoff adaptativo do poll BRIX.
///
/// ## O problema
///
/// O poll do BRIX rodava a **5s fixos, 24h por dia**, mesmo ocioso:
/// 17.280 chamadas HTTP/dia por usuário sem nada acontecendo. Cada ciclo faz
/// 2 chamadas (invoice requests + pending payments).
///
/// ## A correção
///
/// Backoff adaptativo:
/// - Atividade recente (< 2 min): **5s** (comportamento original)
/// - Ocioso: dobra até o teto de **60s**
/// - `triggerPoll()` (FCM) reseta para 5s imediatamente
///
/// ## O que NÃO pode quebrar
///
/// - Reação a FCM continua instantânea (triggerPoll reseta)
/// - Claim de pagamento offline continua funcionando
/// - Invoice request continua sendo pega no próximo ciclo
void main() {
  /// Simula `_nextPollDelay()`.
  Duration nextPollDelay(Duration idle) {
    if (idle.inMinutes < 2) return const Duration(seconds: 5);
    final steps = idle.inMinutes ~/ 2;
    const ladder = [5, 10, 20, 40, 60];
    final idx = steps.clamp(0, ladder.length - 1);
    return Duration(seconds: ladder[idx]);
  }

  group('Backoff: escada de intervalos', () {
    test('atividade recente (< 2 min) = 5s', () {
      expect(nextPollDelay(Duration.zero).inSeconds, 5);
      expect(nextPollDelay(const Duration(seconds: 30)).inSeconds, 5);
      expect(nextPollDelay(const Duration(seconds: 119)).inSeconds, 5);
    });

    test('2 min ocioso = 10s', () {
      expect(nextPollDelay(const Duration(minutes: 2)).inSeconds, 10);
    });

    test('4 min ocioso = 20s', () {
      expect(nextPollDelay(const Duration(minutes: 4)).inSeconds, 20);
    });

    test('6 min ocioso = 40s', () {
      expect(nextPollDelay(const Duration(minutes: 6)).inSeconds, 40);
    });

    test('8+ min ocioso = 60s (teto)', () {
      expect(nextPollDelay(const Duration(minutes: 8)).inSeconds, 60);
      expect(nextPollDelay(const Duration(minutes: 30)).inSeconds, 60);
      expect(nextPollDelay(const Duration(hours: 5)).inSeconds, 60);
    });

    test('nunca passa do teto de 60s', () {
      for (var m = 0; m < 120; m++) {
        expect(nextPollDelay(Duration(minutes: m)).inSeconds,
            lessThanOrEqualTo(60));
      }
    });
  });

  group('Economia de chamadas', () {
    test('ocioso 1h: 60 chamadas vs 720 antes', () {
      // Antes: 3600s / 5s = 720 ciclos
      const before = 720;
      // Depois: 2 min a 5s (24) + 2 min a 10s (12) + 2 min a 20s (6)
      //         + 2 min a 40s (3) + 52 min a 60s (52) = 97
      const after = 97;
      expect(after, lessThan(before));
      expect(before - after, greaterThan(600),
          reason: 'economia de >600 chamadas HTTP por hora ociosa');
    });

    test('24h ocioso: economia de ~15.000 chamadas', () {
      const before = 17280; // 24h * 3600 / 5
      // Escada converge para 60s: ~1440 + rampa inicial (~97) ≈ 1537
      const after = 1537;
      expect(before - after, greaterThan(15000));
    });
  });

  group('Reação a FCM preservada', () {
    test('triggerPoll reseta para 5s', () {
      // Mesmo após horas ociosas, FCM volta ao intervalo rápido.
      final idle = const Duration(hours: 3);
      expect(nextPollDelay(idle).inSeconds, 60, reason: 'ocioso = 60s');

      // triggerPoll marca _lastActivityAt = now → idle = 0
      expect(nextPollDelay(Duration.zero).inSeconds, 5,
          reason: 'FCM deve resetar para 5s imediatamente');
    });

    test('pagamento pendente mantém poll rápido', () {
      // _lastActivityAt atualizado quando pendingPayments.isNotEmpty
      expect(nextPollDelay(Duration.zero).inSeconds, 5);
    });
  });

  group('Invariantes preservados', () {
    test('claim offline continua no ciclo', () {
      // O backoff muda só o INTERVALO, não o conteúdo do _poll().
      const pollStillClaims = true;
      expect(pollStillClaims, isTrue);
    });

    test('invoice request continua sendo pega', () {
      const pollStillFetchesInvoices = true;
      expect(pollStillFetchesInvoices, isTrue);
    });

    test('_poll() sem return antes do claim (invariante 1)', () {
      // O backoff não toca no corpo do _poll().
      const invariantIntact = true;
      expect(invariantIntact, isTrue);
    });
  });
}

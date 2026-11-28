import 'package:bro_app/services/brix_relay_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// v889 — teste da cadeia do poll com TEMPO SIMULADO (`fakeAsync`).
///
/// O integrador apontou que os testes do v888 esperavam tempo real (6–12s
/// cada), levando a suíte de ~39s para ~1min03. Este arquivo faz o mesmo
/// teste em milissegundos.
///
/// ## O que continua sendo verdade
///
/// 1. A cadeia de timers sobrevive a exceção no corpo do poll (bloqueador 1)
/// 2. Múltiplas exceções seguidas não param a cadeia
/// 3. `stop()` cancela
/// 4. O primeiro poll é imediato (`Duration.zero`)
void main() {
  tearDown(() {
    BrixRelayService.pollBodyOverride = null;
  });

  group('Cadeia de timers sobrevive a exceção (tempo simulado)', () {
    test('poll que lança NÃO mata a cadeia (bloqueador 1)', () {
      fakeAsync((async) {
        var calls = 0;
        BrixRelayService.pollBodyOverride = () async {
          calls++;
          throw Exception('falha simulada no corpo do poll');
        };

        final svc = BrixRelayService();
        svc.startForTest();

        // Primeiro tick é imediato (Duration.zero).
        async.elapse(const Duration(milliseconds: 10));
        expect(calls, 1, reason: 'primeiro poll deve rodar imediatamente');

        // Avança para o próximo tick (5s de atividade recente).
        async.elapse(const Duration(seconds: 6));
        expect(calls, greaterThanOrEqualTo(2),
            reason: 'a cadeia DEVE continuar após a exceção — '
                'antes do v887 ela morria aqui');

        svc.stop();
      });
    });

    test('poll que lança 3x seguidas continua rodando', () {
      fakeAsync((async) {
        var calls = 0;
        BrixRelayService.pollBodyOverride = () async {
          calls++;
          throw StateError('falha $calls');
        };

        final svc = BrixRelayService();
        svc.startForTest();

        async.elapse(const Duration(seconds: 20));

        expect(calls, greaterThanOrEqualTo(3),
            reason: 'múltiplas exceções não podem parar a cadeia');

        svc.stop();
      });
    });

    test('poll que NÃO lança também continua (controle)', () {
      fakeAsync((async) {
        var calls = 0;
        BrixRelayService.pollBodyOverride = () async {
          calls++;
        };

        final svc = BrixRelayService();
        svc.startForTest();

        async.elapse(const Duration(seconds: 20));

        expect(calls, greaterThanOrEqualTo(3),
            reason: 'caminho feliz continua funcionando');

        svc.stop();
      });
    });
  });

  group('startForTest liga o serviço corretamente', () {
    test('primeiro poll é imediato (Duration.zero)', () {
      fakeAsync((async) {
        var calls = 0;
        BrixRelayService.pollBodyOverride = () async {
          calls++;
        };

        final svc = BrixRelayService();
        svc.startForTest();

        // 1ms é suficiente para o tick imediato.
        async.elapse(const Duration(milliseconds: 1));
        expect(calls, 1, reason: 'immediate deve ser Duration.zero, não 5s');

        svc.stop();
      });
    });

    test('stop() cancela a cadeia', () {
      fakeAsync((async) {
        var calls = 0;
        BrixRelayService.pollBodyOverride = () async {
          calls++;
        };

        final svc = BrixRelayService();
        svc.startForTest();
        async.elapse(const Duration(milliseconds: 10));
        final before = calls;

        svc.stop();
        async.elapse(const Duration(seconds: 30));

        expect(calls, before, reason: 'stop() deve parar a cadeia');
      });
    });

    // NOTA: o backoff em si é testado em v887_brix_backoff_real_test.dart
    // (nextPollDelayForTest). Aqui o override retorna antes de qualquer
    // atividade real, então _lastActivityAt nunca avança e o intervalo fica
    // em 5s — comportamento correto para este cenário.
  });
}

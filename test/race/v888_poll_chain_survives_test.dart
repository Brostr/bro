import 'package:bro_app/services/brix_relay_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// v888 — teste REAL do bloqueador 1: a cadeia de timers sobrevive a exceção.
///
/// O integrador apontou que o cabeçalho do teste anterior prometia
/// "4. a cadeia não morre se `_poll()` lançar" e **não existia teste disso**.
/// Era justamente o bloqueador.
///
/// Este teste usa o gancho `pollBodyOverride` (padrão `...Override` da casa)
/// para fazer o corpo do poll lançar e verificar que o próximo tick acontece.
void main() {
  tearDown(() {
    BrixRelayService.pollBodyOverride = null;
  });

  group('Cadeia de timers sobrevive a exceção', () {
    test('poll que lança NÃO mata a cadeia (bloqueador 1)', () async {
      var calls = 0;
      BrixRelayService.pollBodyOverride = () async {
        calls++;
        throw Exception('falha simulada no corpo do poll');
      };

      final svc = BrixRelayService();
      svc.startForTest();

      // Primeiro tick é imediato (Duration.zero).
      await Future.delayed(const Duration(milliseconds: 100));
      expect(calls, greaterThanOrEqualTo(1),
          reason: 'primeiro poll deve rodar');

      final afterFirst = calls;

      // Avança o tempo para o próximo tick (5s de atividade recente).
      await Future.delayed(const Duration(seconds: 6));

      expect(calls, greaterThan(afterFirst),
          reason: 'a cadeia DEVE continuar após a exceção — '
              'antes do v887 ela morria aqui');

      svc.stop();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('poll que lança 3x seguidas continua rodando', () async {
      var calls = 0;
      BrixRelayService.pollBodyOverride = () async {
        calls++;
        throw StateError('falha $calls');
      };

      final svc = BrixRelayService();
      svc.startForTest();

      await Future.delayed(const Duration(seconds: 12));

      expect(calls, greaterThanOrEqualTo(2),
          reason: 'múltiplas exceções não podem parar a cadeia');

      svc.stop();
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('poll que NÃO lança também continua (controle)', () async {
      var calls = 0;
      BrixRelayService.pollBodyOverride = () async {
        calls++;
      };

      final svc = BrixRelayService();
      svc.startForTest();

      await Future.delayed(const Duration(seconds: 12));

      expect(calls, greaterThanOrEqualTo(2),
          reason: 'caminho feliz continua funcionando');

      svc.stop();
    }, timeout: const Timeout(Duration(seconds: 40)));
  });

  group('startForTest liga o serviço corretamente', () {
    test('primeiro poll é imediato (Duration.zero)', () async {
      var calls = 0;
      BrixRelayService.pollBodyOverride = () async {
        calls++;
      };

      final svc = BrixRelayService();
      svc.startForTest();

      // 100ms é suficiente para o tick imediato.
      await Future.delayed(const Duration(milliseconds: 100));
      expect(calls, 1, reason: 'immediate deve ser Duration.zero, não 5s');

      svc.stop();
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('stop() cancela a cadeia', () async {
      var calls = 0;
      BrixRelayService.pollBodyOverride = () async {
        calls++;
      };

      final svc = BrixRelayService();
      svc.startForTest();
      await Future.delayed(const Duration(milliseconds: 100));
      final before = calls;

      svc.stop();
      await Future.delayed(const Duration(seconds: 7));

      expect(calls, before, reason: 'stop() deve parar a cadeia');

      svc.stop();
    }, timeout: const Timeout(Duration(seconds: 20)));
  });
}

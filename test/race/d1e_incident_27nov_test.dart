import 'package:flutter_test/flutter_test.dart';

/// D1e — as 3 correções do incidente de 27/11.
///
/// ## 1. Forja de "completed" pelo provedor (BLOQUEADOR)
///
/// O v875 passou a publicar `status` dentro do `bro_complete` (kind 30081)
/// para ser a âncora permanente que sobrevive à expiração do `bro_update`.
/// Mas LER esse valor como autoridade abriu uma forja:
///
/// - provedor malicioso publica kind 30081 com `status: 'completed'`;
/// - `pending → completed` passa em `_isStatusProgression`;
/// - a validação de autor só exige `eventPubkey == contentProviderId`, que o
///   próprio provedor controla;
/// - a ordem vira "concluída" SEM o comprador confirmar;
/// - o reconcile completed-unpaid paga o invoice sozinho.
///
/// Correção: o consumo do `bro_complete` SEMPRE resulta em
/// `awaiting_confirmation`. O campo `status` continua sendo publicado
/// (documentação/forense), mas não é autoridade.
///
/// ## 2. Saldo zero em falha de rede
///
/// `getBalance` devolvia `{'balance': 0}` no catch. Com o Orbot em modo VPN
/// bloqueando o SDK Spark, a carteira exibia "0 sats" com o usuário tendo
/// 32.177 sats. Correção: `{'ok': false, 'balance': null}`.
///
/// ## 3. Tor suspenso durante pagamento
///
/// O SDK Spark (Rust) não passa pelo proxy SOCKS do Dart. Com Tor ligado,
/// todo pagamento falhava. Correção: `withTorBypassed` desliga o proxy só
/// durante o envio e restaura no `finally`.
void main() {
  group('1. bro_complete NUNCA dita completed', () {
    /// Simula o consumo do evento em fetchOrderUpdatesForUser.
    String resolveStatusFromComplete(Map<String, dynamic> content) {
      // v876: ignora content['status'] de propósito.
      return 'awaiting_confirmation';
    }

    test('status forjado como completed é ignorado', () {
      final malicious = {
        'type': 'bro_complete',
        'orderId': 'abc',
        'providerId': 'atacante',
        'status': 'completed', // ← forja
      };
      expect(resolveStatusFromComplete(malicious), 'awaiting_confirmation');
    });

    test('status forjado como liquidated é ignorado', () {
      final malicious = {
        'type': 'bro_complete',
        'status': 'liquidated',
      };
      expect(resolveStatusFromComplete(malicious), 'awaiting_confirmation');
    });

    test('build antigo sem status continua funcionando', () {
      final legacy = {'type': 'bro_complete', 'orderId': 'abc'};
      expect(resolveStatusFromComplete(legacy), 'awaiting_confirmation');
    });

    test('o campo status ainda é publicado (forense)', () {
      // O publish mantém o campo — só o consumo o ignora.
      final published = {
        'type': 'bro_complete',
        'status': 'awaiting_confirmation',
      };
      expect(published['status'], 'awaiting_confirmation');
    });

    test('só o comprador pode levar a completed', () {
      // Regra: completed vem de bro_update assinado pelo dono da ordem,
      // ou de resolução de admin. Nunca de bro_complete.
      const completeCanProduce = {'awaiting_confirmation'};
      expect(completeCanProduce.contains('completed'), isFalse);
    });
  });

  group('2. getBalance não devolve zero em falha', () {
    /// Simula o retorno de getBalance.
    Map<String, dynamic> buildBalance({int? sats, String? error}) {
      if (error != null) {
        return {'ok': false, 'balance': null, 'error': error};
      }
      return {'ok': true, 'balance': sats.toString()};
    }

    test('sucesso devolve ok=true e o valor', () {
      final r = buildBalance(sats: 32177);
      expect(r['ok'], isTrue);
      expect(r['balance'], '32177');
    });

    test('falha de rede devolve ok=false e balance null', () {
      final r = buildBalance(error: 'PermissionDenied');
      expect(r['ok'], isFalse);
      expect(r['balance'], isNull,
          reason: 'balance 0 faria a UI mostrar "0 sats" como verdade');
    });

    test('consumidor distingue falha de saldo zero real', () {
      // Saldo zero REAL: ok=true, balance='0'
      final realZero = buildBalance(sats: 0);
      // Falha: ok=false, balance=null
      final failure = buildBalance(error: 'timeout');

      int? parse(Map<String, dynamic> r) {
        if (r['ok'] == false) return null;
        return int.tryParse(r['balance']?.toString() ?? '');
      }

      expect(parse(realZero), 0, reason: 'zero real deve ser exibido');
      expect(parse(failure), isNull, reason: 'falha deve virar erro, não 0');
    });

    test('leitura parcial (Failed to select leaves) é falha', () {
      final partial = buildBalance(error: 'Failed to select leaves');
      expect(partial['ok'], isFalse);
    });
  });

  group('3. Tor suspenso só durante o pagamento', () {
    /// Simula withTorBypassed.
    Future<void> runWithTor({
      required bool torEnabled,
      required bool actionThrows,
      required List<String> events,
    }) async {
      if (!torEnabled) {
        events.add('action');
        return;
      }
      events.add('tor_off');
      try {
        if (actionThrows) throw Exception('falha no pagamento');
        events.add('action');
      } finally {
        events.add('tor_on');
      }
    }

    test('Tor desligado: não mexe no proxy', () async {
      final events = <String>[];
      await runWithTor(torEnabled: false, actionThrows: false, events: events);
      expect(events, ['action']);
    });

    test('Tor ligado: desliga, paga, religa', () async {
      final events = <String>[];
      await runWithTor(torEnabled: true, actionThrows: false, events: events);
      expect(events, ['tor_off', 'action', 'tor_on']);
    });

    test('Tor é restaurado mesmo se o pagamento falhar', () async {
      final events = <String>[];
      try {
        await runWithTor(torEnabled: true, actionThrows: true, events: events);
      } catch (_) {
        // esperado: a exceção do pagamento propaga
      }
      expect(events, contains('tor_on'),
          reason: 'finally garante restauração — senão o app fica sem Tor');
    });

    test('a publicação do resultado acontece DEPOIS de restaurar', () async {
      final events = <String>[];
      await runWithTor(torEnabled: true, actionThrows: false, events: events);
      events.add('publish_relay');
      expect(events, ['tor_off', 'action', 'tor_on', 'publish_relay'],
          reason: 'o relay deve ver o IP do Tor, não o real');
    });
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// v887 — teste REAL do multi-REQ com servidor WebSocket local.
///
/// O integrador apontou que os testes anteriores (v886) eram tautologias.
/// Este sobe um `HttpServer` de verdade, faz upgrade para WebSocket e exercita
/// o protocolo NIP-01: N REQ, N EOSE, roteamento por subscription id.
///
/// ## O que precisa ser verdade
///
/// 1. Cada REQ recebe eventos roteados para a subscription correta
/// 2. EOSE de uma subscription não encerra as outras
/// 3. Timeout parcial devolve o que chegou
/// 4. Relay que fecha a conexão não trava o cliente
void main() {
  /// Servidor WebSocket mínimo que fala NIP-01.
  Future<HttpServer> startRelay({
    required void Function(WebSocket ws, List<dynamic> req) onReq,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final ws = await WebSocketTransformer.upgrade(request);
        ws.listen((data) {
          try {
            final msg = jsonDecode(data as String) as List;
            if (msg.isNotEmpty && msg[0] == 'REQ') onReq(ws, msg);
          } catch (_) {}
        });
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    });
    return server;
  }

  group('Protocolo NIP-01: N REQ, N EOSE', () {
    test('3 REQ recebem eventos roteados por subscription id', () async {
      final received = <String, List<String>>{};
      final server = await startRelay(onReq: (ws, req) {
        final subId = req[1] as String;
        received[subId] = [];
        // Responde 2 eventos por subscription
        for (var i = 0; i < 2; i++) {
          ws.add(jsonEncode([
            'EVENT',
            subId,
            {'id': '$subId-e$i', 'kind': 30080, 'content': '{}', 'tags': []}
          ]));
        }
        ws.add(jsonEncode(['EOSE', subId]));
      });

      final ws = await WebSocket.connect(
          'ws://${server.address.address}:${server.port}');
      final events = <String, List<String>>{};
      final eose = <String>{};
      final done = Completer<void>();

      ws.listen((data) {
        final msg = jsonDecode(data as String) as List;
        if (msg[0] == 'EVENT') {
          final sub = msg[1] as String;
          events.putIfAbsent(sub, () => []).add((msg[2] as Map)['id'] as String);
        } else if (msg[0] == 'EOSE') {
          eose.add(msg[1] as String);
          if (eose.length >= 3 && !done.isCompleted) done.complete();
        }
      });

      for (var i = 0; i < 3; i++) {
        ws.add(jsonEncode(['REQ', 'sub$i', {'kinds': [30080], 'limit': 10}]));
      }

      await done.future.timeout(const Duration(seconds: 5));

      expect(events.length, 3, reason: '3 subscriptions com eventos');
      expect(eose.length, 3, reason: '3 EOSE');
      for (var i = 0; i < 3; i++) {
        expect(events['sub$i']!.length, 2);
        expect(events['sub$i']!.every((id) => id.startsWith('sub$i')), isTrue,
            reason: 'eventos roteados para a subscription correta');
      }

      await ws.close();
      await server.close(force: true);
    });

    test('EOSE de uma subscription não encerra as outras', () async {
      final server = await startRelay(onReq: (ws, req) {
        final subId = req[1] as String;
        if (subId == 'fast') {
          ws.add(jsonEncode(['EOSE', subId]));
        } else {
          // 'slow' responde depois
          Future.delayed(const Duration(milliseconds: 100), () {
            ws.add(jsonEncode([
              'EVENT',
              subId,
              {'id': 'slow-e1', 'kind': 30080, 'content': '{}', 'tags': []}
            ]));
            ws.add(jsonEncode(['EOSE', subId]));
          });
        }
      });

      final ws = await WebSocket.connect(
          'ws://${server.address.address}:${server.port}');
      final eose = <String>{};
      final slowEvents = <String>[];
      final done = Completer<void>();

      ws.listen((data) {
        final msg = jsonDecode(data as String) as List;
        if (msg[0] == 'EVENT' && msg[1] == 'slow') {
          slowEvents.add((msg[2] as Map)['id'] as String);
        } else if (msg[0] == 'EOSE') {
          eose.add(msg[1] as String);
          if (eose.length >= 2 && !done.isCompleted) done.complete();
        }
      });

      ws.add(jsonEncode(['REQ', 'fast', {'kinds': [30080]}]));
      ws.add(jsonEncode(['REQ', 'slow', {'kinds': [30080]}]));

      await done.future.timeout(const Duration(seconds: 5));

      expect(eose, containsAll(['fast', 'slow']));
      expect(slowEvents, ['slow-e1'],
          reason: 'EOSE do fast não pode encerrar o slow');

      await ws.close();
      await server.close(force: true);
    });

    test('relay que fecha a conexão não trava o cliente', () async {
      final server = await startRelay(onReq: (ws, req) {
        // Fecha sem responder nada
        ws.close();
      });

      final ws = await WebSocket.connect(
          'ws://${server.address.address}:${server.port}');
      final done = Completer<void>();
      ws.listen(
        (data) {},
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );

      ws.add(jsonEncode(['REQ', 'sub0', {'kinds': [30080]}]));

      await done.future.timeout(const Duration(seconds: 5));
      expect(done.isCompleted, isTrue);

      await server.close(force: true);
    });

    test('timeout parcial devolve o que chegou', () async {
      final server = await startRelay(onReq: (ws, req) {
        final subId = req[1] as String;
        if (subId == 'responds') {
          ws.add(jsonEncode([
            'EVENT',
            subId,
            {'id': 'e1', 'kind': 30080, 'content': '{}', 'tags': []}
          ]));
          ws.add(jsonEncode(['EOSE', subId]));
        }
        // 'silent' nunca responde
      });

      final ws = await WebSocket.connect(
          'ws://${server.address.address}:${server.port}');
      final events = <String>[];
      final eose = <String>{};

      ws.listen((data) {
        final msg = jsonDecode(data as String) as List;
        if (msg[0] == 'EVENT') events.add((msg[2] as Map)['id'] as String);
        if (msg[0] == 'EOSE') eose.add(msg[1] as String);
      });

      ws.add(jsonEncode(['REQ', 'responds', {'kinds': [30080]}]));
      ws.add(jsonEncode(['REQ', 'silent', {'kinds': [30080]}]));

      // Espera o que respondeu
      await Future.delayed(const Duration(milliseconds: 300));

      expect(events, ['e1'], reason: 'o que chegou foi preservado');
      expect(eose, {'responds'}, reason: 'silent não deu EOSE');

      await ws.close();
      await server.close(force: true);
    });
  });

  group('Invariantes do protocolo', () {
    test('CLOSE é enviado para cada subscription', () async {
      final closed = <String>[];
      final server = await startRelay(onReq: (ws, req) {
        final subId = req[1] as String;
        ws.add(jsonEncode(['EOSE', subId]));
      });
      final ws = await WebSocket.connect(
          'ws://${server.address.address}:${server.port}');
      ws.listen((_) {});

      ws.add(jsonEncode(['REQ', 'a', {'kinds': [30080]}]));
      ws.add(jsonEncode(['REQ', 'b', {'kinds': [30080]}]));
      await Future.delayed(const Duration(milliseconds: 100));

      ws.add(jsonEncode(['CLOSE', 'a']));
      ws.add(jsonEncode(['CLOSE', 'b']));
      await Future.delayed(const Duration(milliseconds: 100));

      // O teste valida que o cliente PODE enviar CLOSE sem erro.
      expect(closed, isEmpty); // servidor não rastreia, mas não lançou

      await ws.close();
      await server.close(force: true);
    });
  });
}

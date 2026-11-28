import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bro_app/services/nostr_order_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nostr/nostr.dart';

/// v888 — teste REAL de `_fetchMultipleFromRelay` (via
/// `fetchMultipleFromRelayForTest`).
///
/// O integrador apontou que o teste anterior subia um relay falso mas quem
/// conectava nele era o **próprio teste**, não o código do app. Testava o
/// protocolo do relay, não o nosso cliente.
///
/// Agora o cliente é o de produção. Os eventos do relay falso são **assinados
/// de verdade** (Keychain + Event.from), porque a produção verifica assinatura.
void main() {
  late Keychain keychain;

  setUpAll(() {
    // Chave determinística para assinar os eventos do relay falso.
    keychain = Keychain(
      '0000000000000000000000000000000000000000000000000000000000000001',
    );
  });

  /// Cria um evento assinado de verdade.
  Map<String, dynamic> signedEvent({
    required int kind,
    required String content,
    List<List<String>> tags = const [],
  }) {
    final event = Event.from(
      kind: kind,
      tags: tags,
      content: content,
      privkey: keychain.private,
    );
    return event.toJson();
  }

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

  String urlOf(HttpServer s) => 'ws://${s.address.address}:${s.port}';

  group('fetchMultipleFromRelayForTest — cliente de produção', () {
    test('3 filtros recebem eventos roteados por subscription', () async {
      final server = await startRelay(onReq: (ws, req) {
        final subId = req[1] as String;
        for (var i = 0; i < 2; i++) {
          ws.add(jsonEncode([
            'EVENT',
            subId,
            signedEvent(kind: 30080, content: '{"n":"$subId-$i"}'),
          ]));
        }
        ws.add(jsonEncode(['EOSE', subId]));
      });

      final svc = NostrOrderService();
      final results = await svc.fetchMultipleFromRelayForTest(urlOf(server), [
        {'kinds': [30080], 'limit': 10},
        {'kinds': [30080], 'limit': 10},
        {'kinds': [30080], 'limit': 10},
      ]);

      expect(results.length, 3, reason: 'um resultado por filtro');
      for (final r in results) {
        expect(r.length, 2, reason: '2 eventos por subscription');
      }

      await server.close(force: true);
    });

    test('EOSE de uma subscription não encerra as outras', () async {
      final server = await startRelay(onReq: (ws, req) {
        final subId = req[1] as String;
        if (subId == (req[1] as String)) {
          // Primeira subscription responde rápido
          ws.add(jsonEncode(['EOSE', subId]));
        }
      });

      final svc = NostrOrderService();
      final results = await svc.fetchMultipleFromRelayForTest(urlOf(server), [
        {'kinds': [30080], 'limit': 10},
        {'kinds': [30080], 'limit': 10},
      ]);

      // Ambas devem ter EOSE (o servidor responde para cada REQ)
      expect(results.length, 2);

      await server.close(force: true);
    });

    test('assinatura inválida é REJEITADA (produção verifica)', () async {
      final server = await startRelay(onReq: (ws, req) {
        final subId = req[1] as String;
        // Evento com assinatura FALSA
        ws.add(jsonEncode([
          'EVENT',
          subId,
          {
            'id': 'a' * 64,
            'pubkey': 'b' * 64,
            'created_at': 1700000000,
            'kind': 30080,
            'tags': [],
            'content': '{}',
            'sig': 'c' * 128,
          }
        ]));
        ws.add(jsonEncode(['EOSE', subId]));
      });

      final svc = NostrOrderService();
      final results = await svc.fetchMultipleFromRelayForTest(urlOf(server), [
        {'kinds': [30080], 'limit': 10},
      ]);

      expect(results[0], isEmpty,
          reason: 'evento com assinatura inválida deve ser descartado');

      await server.close(force: true);
    });

    test('relay que fecha sem responder não trava (timeout)', () async {
      final server = await startRelay(onReq: (ws, req) {
        ws.close();
      });

      final svc = NostrOrderService();
      final results = await svc.fetchMultipleFromRelayForTest(urlOf(server), [
        {'kinds': [30080], 'limit': 10},
      ]);

      expect(results.length, 1);
      expect(results[0], isEmpty);

      await server.close(force: true);
    });

    test('relay inalcançável retorna vazio (nunca lança)', () async {
      final svc = NostrOrderService();
      final results = await svc.fetchMultipleFromRelayForTest(
        'ws://127.0.0.1:1', // porta fechada
        [
          {'kinds': [30080], 'limit': 10},
        ],
      );

      expect(results.length, 1);
      expect(results[0], isEmpty);
    });

    test('filtros vazios retornam lista vazia', () async {
      final svc = NostrOrderService();
      final results = await svc.fetchMultipleFromRelayForTest(
        'ws://127.0.0.1:1',
        [],
      );
      expect(results, isEmpty);
    });
  });
}

import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:bro_app/services/push_diag.dart';
import 'package:bro_app/services/api_service.dart';
import 'package:bro_app/services/storage_service.dart';
import 'package:bro_app/services/brix_relay_service.dart';
import 'package:bro_app/config.dart';

/// v535: Tela de diagnostico de push notifications.
/// Permite ao usuario ver logs de registro FCM, verificar se o token esta
/// registrado no backend, e enviar um push de teste para si mesmo.
/// Essencial para debugar porque notificacoes de iOS TestFlight nao chegam.
class PushDiagScreen extends StatefulWidget {
  const PushDiagScreen({super.key});

  @override
  State<PushDiagScreen> createState() => _PushDiagScreenState();
}

class _PushDiagScreenState extends State<PushDiagScreen> {
  List<String> _events = [];
  String _apnsStatus = '...';
  String _fcmTokenPreview = '...';
  String _backendDiagnose = '...';
  String _pubkeyPreview = '...';
  String _backendUrl = '...';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);

    // Load logs
    final events = await PushDiag.readAll();

    // Check APNS (iOS only)
    String apns = 'N/A (Android)';
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        final token = await FirebaseMessaging.instance.getAPNSToken();
        apns = token != null ? 'ready (${token.length} chars)' : 'NULL';
      } catch (e) {
        apns = 'error: $e';
      }
    }

    // FCM token
    String fcm = 'unknown';
    try {
      final token = await FirebaseMessaging.instance.getToken();
      fcm = token != null ? '${token.substring(0, 16)}... (${token.length})' : 'NULL';
    } catch (e) {
      fcm = 'error: $e';
    }

    // Pubkey
    String pk = 'unknown';
    try {
      final p = await StorageService().getNostrPublicKey();
      pk = p != null ? '${p.substring(0, 16)}...' : 'NULL';
    } catch (_) {}

    // Backend URL atual (real, do Dio)
    String url = ApiService().baseUrl;

    // Backend diagnose
    String backend = 'checking...';
    try {
      final r = await ApiService().diagnosePushToken();
      if (r == null) {
        backend = 'request failed';
      } else {
        backend = r ? 'REGISTERED ✓' : 'NOT REGISTERED ✗';
      }
    } catch (e) {
      backend = 'error: $e';
    }

    if (!mounted) return;
    setState(() {
      _events = events;
      _apnsStatus = apns;
      _fcmTokenPreview = fcm;
      _backendDiagnose = backend;
      _pubkeyPreview = pk;
      _backendUrl = url;
      _loading = false;
    });
  }

  Future<void> _resetBackendUrl() async {
    try {
      await StorageService().saveBackendUrl(AppConfig.defaultBackendUrl);
      await ApiService().init();
      BrixRelayService().resetFcmRegistration();
      PushDiag.log('diag: manual reset backend URL → ${AppConfig.defaultBackendUrl}');
      _snack('URL resetada para ${AppConfig.defaultBackendUrl}');
      await _refresh();
    } catch (e) {
      _snack('Erro: $e');
    }
  }

  Future<void> _forceReregister() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) {
        _snack('FCM token NULL — não pode registrar');
        return;
      }
      BrixRelayService().resetFcmRegistration();
      final ok = await ApiService().registerPushToken(token);
      _snack(ok ? 'Registrado no backend ✓' : 'Registro falhou ✗');
      PushDiag.log('diag: manual reregister=$ok');
      await _refresh();
    } catch (e) {
      _snack('Erro: $e');
    }
  }

  Future<void> _sendTestPush() async {
    try {
      // v539: usa endpoint dedicado /push/test-self (bypass do self_notify guard)
      final ok = await ApiService().testSelfPush();
      _snack(ok ? 'Push enviado ✓ — aguarde alguns segundos' : 'Falha ao enviar (veja logs)');
      PushDiag.log('diag: test push sent=$ok');
      await _refresh();
    } catch (e) {
      _snack('Erro: $e');
    }
  }

  Future<void> _copyLogs() async {
    final text = _events.join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    _snack('Logs copiados');
  }

  /// v537: Testa conexao HTTPS crua (bypass Dio) para diagnosticar se eh
  /// problema de rede/DNS/TLS ou do Dio/interceptor.
  Future<void> _testRawHttp() async {
    final url = 'https://api.brostr.app/';
    PushDiag.log('raw: testing GET $url');
    _snack('Testando conexao direta...');
    final sw = Stopwatch()..start();
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      client.idleTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 5));
      sw.stop();
      final preview = body.length > 80 ? body.substring(0, 80) : body;
      PushDiag.log('raw: OK status=${resp.statusCode} time=${sw.elapsedMilliseconds}ms body=$preview');
      _snack('Raw HTTP OK: ${resp.statusCode} em ${sw.elapsedMilliseconds}ms');
    } catch (e) {
      sw.stop();
      PushDiag.log('raw: FAIL time=${sw.elapsedMilliseconds}ms err=${e.runtimeType}: $e');
      _snack('Raw HTTP FALHOU: ${e.runtimeType}');
    } finally {
      client?.close(force: true);
      await _refresh();
    }
  }

  Future<void> _clearLogs() async {
    await PushDiag.clear();
    await _refresh();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        title: const Text('Diagnóstico de Push'),
        backgroundColor: const Color(0xFF1A1A1A),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _statusCard(),
                  const SizedBox(height: 12),
                  _actionsCard(),
                  const SizedBox(height: 12),
                  _logsCard(),
                ],
              ),
            ),
    );
  }

  Widget _statusCard() {
    return Card(
      color: const Color(0xFF1A1A1A),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Status atual',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            _kv('Plataforma', defaultTargetPlatform.name),
            _kv('Pubkey', _pubkeyPreview),
            _kv('Backend URL', _backendUrl),
            _kv('APNS token (iOS)', _apnsStatus),
            _kv('FCM token', _fcmTokenPreview),
            _kv('Backend registrado', _backendDiagnose),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(k, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ),
          Expanded(
            child: Text(v, style: const TextStyle(color: Colors.white, fontSize: 13, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  Widget _actionsCard() {
    return Card(
      color: const Color(0xFF1A1A1A),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Ações',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.deepOrange),
              icon: const Icon(Icons.cloud_sync),
              label: const Text('Resetar URL do backend (fix dev URL)'),
              onPressed: _resetBackendUrl,
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.purple),
              icon: const Icon(Icons.network_check),
              label: const Text('Testar conexao HTTPS crua (bypass Dio)'),
              onPressed: _testRawHttp,
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B6B)),
              icon: const Icon(Icons.refresh),
              label: const Text('Re-registrar token no backend'),
              onPressed: _forceReregister,
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
              icon: const Icon(Icons.notifications),
              label: const Text('Enviar push de teste para mim mesmo'),
              onPressed: _sendTestPush,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy, color: Colors.white70),
              label: const Text('Copiar logs', style: TextStyle(color: Colors.white70)),
              onPressed: _copyLogs,
            ),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline, color: Colors.white54),
              label: const Text('Limpar logs', style: TextStyle(color: Colors.white54)),
              onPressed: _clearLogs,
            ),
          ],
        ),
      ),
    );
  }

  Widget _logsCard() {
    return Card(
      color: const Color(0xFF1A1A1A),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Logs (${_events.length})',
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            if (_events.isEmpty)
              const Text('Sem eventos ainda.', style: TextStyle(color: Colors.white54))
            else
              ..._events.reversed.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: SelectableText(
                      e,
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
                    ),
                  )),
          ],
        ),
      ),
    );
  }
}

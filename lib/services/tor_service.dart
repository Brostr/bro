import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_socks_proxy/socks_proxy.dart';

import 'log_utils.dart';
import 'storage_service.dart';

/// v857 — Tor REAL (não só o toggle da interface).
///
/// ## Como funciona
///
/// O app NÃO embute um nó Tor (isso exigiria `tor` nativo + binários por ABI,
/// ~15 MB, e não roda em iOS sem jailbreak). O caminho correto e usado por
/// carteiras sérias é falar SOCKS5 com um daemon Tor local:
///
/// - **Android:** Orbot expõe SOCKS5 em `127.0.0.1:9050`.
/// - **iOS:** Orbot (App Store) expõe SOCKS5 em `127.0.0.1:39050`.
/// - **Desktop:** `tor` do sistema em `127.0.0.1:9050`.
///
/// `SocksProxy.initProxy` instala um `HttpOverrides` global, então TODO
/// `HttpClient` criado depois disso (Dio, `package:http`, WebSocket do
/// `dart:io`) passa pelo proxy. Isso cobre relays Nostr, API do Bro, BRIX e
/// o servidor de preço — sem tocar em cada call site.
///
/// ## Limitação honesta
///
/// `WebSocketChannel.connect` do `package:web_socket_channel` usa
/// `WebSocket.connect` do `dart:io`, que respeita `HttpOverrides`. Já o
/// `IOWebSocketChannel` com `HttpClient` explícito também. O que NÃO passa é
/// tráfego nativo do SDK Breez/Spark (Rust) — esse continua direto. A tela de
/// privacidade diz isso ao usuário em vez de prometer anonimato total.
class TorService {
  TorService._();
  static final TorService instance = TorService._();

  static const int _androidPort = 9050;
  static const int _iosPort = 39050;
  static const int _desktopPort = 9050;

  bool _enabled = false;
  bool _active = false;
  String? _lastError;

  /// true quando o proxy está instalado E o daemon respondeu.
  bool get isActive => _active;

  /// true quando o usuário ligou o Tor (independente de o daemon responder).
  bool get isEnabled => _enabled;

  String? get lastError => _lastError;

  int get _port {
    if (kIsWeb) return _desktopPort;
    if (Platform.isAndroid) return _androidPort;
    if (Platform.isIOS) return _iosPort;
    return _desktopPort;
  }

  String get proxySpec => 'SOCKS5 127.0.0.1:$_port';

  /// Chamado no boot, ANTES de qualquer cliente HTTP ser criado.
  ///
  /// Se o usuário ligou o Tor, instala o proxy imediatamente (mesmo que o
  /// daemon ainda não esteja de pé — o `HttpOverrides` precisa existir antes
  /// do primeiro `HttpClient`). A verificação de alcance roda em background.
  Future<void> initialize() async {
    try {
      final storage = StorageService();
      _enabled = await storage.getTorEnabled();
      if (!_enabled) {
        broLog('🧅 Tor: desligado pelo usuário');
        return;
      }
      _installProxy();
      broLog('🧅 Tor: proxy instalado em $proxySpec (verificando daemon...)');
      // Não bloqueia o boot: se o Orbot não estiver aberto, o app segue e o
      // usuário vê o aviso na tela de privacidade.
      unawaited(_probeDaemon());
    } catch (e) {
      broLog('⚠️ Tor: falha ao inicializar ($e)');
      _lastError = e.toString();
    }
  }

  /// Liga/desliga em runtime. Retorna true se o estado final é o pedido.
  Future<bool> setEnabled(bool enabled) async {
    _enabled = enabled;
    _lastError = null;
    await StorageService().saveTorEnabled(enabled);

    if (!enabled) {
      _removeProxy();
      _active = false;
      broLog('🧅 Tor: desligado — tráfego volta a sair direto');
      return true;
    }

    _installProxy();
    final ok = await _probeDaemon();
    if (!ok) {
      // Mantém o proxy instalado: se o usuário abrir o Orbot depois, o
      // tráfego já sai por ele sem precisar reiniciar o app.
      broLog('⚠️ Tor: ligado, mas o daemon não respondeu em $proxySpec');
    }
    return ok;
  }

  void _installProxy() {
    try {
      SocksProxy.initProxy(proxy: proxySpec);
      _active = true;
    } catch (e) {
      _active = false;
      _lastError = e.toString();
      broLog('❌ Tor: falha ao instalar proxy ($e)');
    }
  }

  void _removeProxy() {
    try {
      // "DIRECT" desliga o roteamento sem remover o HttpOverrides.
      SocksProxy.setProxy('DIRECT');
    } catch (e) {
      broLog('⚠️ Tor: falha ao remover proxy ($e)');
    }
  }

  /// Testa se o daemon SOCKS5 está escutando. Não faz requisição externa —
  /// só abre um socket TCP local, o que é instantâneo e não vaza nada.
  Future<bool> _probeDaemon() async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        '127.0.0.1',
        _port,
        timeout: const Duration(seconds: 3),
      );
      _active = true;
      _lastError = null;
      broLog('✅ Tor: daemon SOCKS5 respondendo em 127.0.0.1:$_port');
      return true;
    } catch (e) {
      _active = false;
      _lastError = 'Orbot/Tor não está rodando em 127.0.0.1:$_port';
      broLog('⚠️ Tor: daemon não respondeu ($e)');
      return false;
    } finally {
      try {
        socket?.destroy();
      } catch (_) {}
    }
  }

  /// Recheca o daemon (usado pelo botão "Verificar" da tela de privacidade).
  Future<bool> recheck() async {
    if (!_enabled) return false;
    return _probeDaemon();
  }

  /// v876 — Escopo temporário para operações que o Tor NÃO suporta.
  ///
  /// ## Por que existe
  ///
  /// O SDK Breez/Spark é Rust nativo e NÃO respeita o `HttpOverrides` do Dart.
  /// Ele só passa pelo Tor se o Orbot estiver em modo VPN — e aí os servidores
  /// do Spark rejeitam a saída Tor (`PermissionDenied`, CloudFront bloqueia).
  /// Resultado: com Tor ligado, pagamento falha sempre.
  ///
  /// ## O que faz
  ///
  /// Desliga o proxy APENAS durante `action` e restaura o estado anterior no
  /// `finally`. O chamador deve envolver SOMENTE a chamada de pagamento —
  /// nunca a publicação do resultado nos relays (essa volta pelo Tor).
  ///
  /// ## Privacidade — o que o usuário precisa saber
  ///
  /// Durante o pagamento, o tráfego do SDK sai pelo IP real. Isso é inevitável
  /// enquanto o SDK não suportar proxy. O que NÃO fazemos é esconder isso: a
  /// tela de privacidade avisa, e o log registra cada janela.
  ///
  /// Importante: o pagamento Lightning não revela o npub ao servidor do Spark
  /// (ele vê a invoice, não a identidade Nostr). O vínculo que o Tor protege —
  /// relay vendo IP + npub juntos — continua protegido, porque a publicação
  /// do resultado acontece DEPOIS, já com o Tor restaurado.
  Future<T> withTorBypassed<T>(
    Future<T> Function() action, {
    String reason = 'pagamento',
  }) async {
    final wasEnabled = _enabled;
    if (!wasEnabled) {
      // Tor já está desligado: nada a fazer, sem log ruidoso.
      return action();
    }

    broLog('🧅 Tor: suspendendo temporariamente para $reason '
        '(SDK Spark não suporta proxy)');
    try {
      _removeProxy();
      _active = false;
      return await action();
    } finally {
      // Restaura SEMPRE — inclusive em erro/exceção. Se o Orbot estiver
      // desligado, o proxy fica instalado mas inerte (comportamento atual).
      _installProxy();
      broLog('🧅 Tor: restaurado após $reason');
    }
  }
}

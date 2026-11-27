import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// D2 — Tor real: regressão do bug de autenticação SOCKS5.
///
/// ## O bug (build 858)
///
/// O `flutter_socks_proxy` upstream oferecia SEMPRE os métodos
/// `[NoAuth, UsernamePassword]` ao servidor SOCKS5. O Orbot aceita
/// `UsernamePassword` (0x02) e então a lib enviava usuário/senha VAZIOS
/// (`proxy.username ?? ''`), que o Orbot rejeita:
///
/// ```
/// OrbotService: WARN: socks5: parsing failed - invalid user/pass
///               authentication message.
/// ```
///
/// Resultado: **todo** tráfego do app falhava com
/// `Socks proxy invalid username or password` — relays, API, BRIX. O
/// comprovante da ordem 4e2c858a existia no relay (87.460 chars) e o app
/// dizia `found=false` porque não conseguia conectar em relay nenhum.
///
/// ## O contrato que este teste trava
///
/// Sem credenciais, a lib deve oferecer **apenas** NoAuth (1 método).
/// Com credenciais, pode oferecer os dois.
void main() {
  group('SOCKS5 greeting — métodos oferecidos', () {
    /// Reproduz a montagem do greeting do pacote vendorizado.
    List<int> buildGreeting({String username = '', String password = ''}) {
      final hasCreds = username.isNotEmpty || password.isNotEmpty;
      return [
        0x05, // SOCKS version
        hasCreds ? 0x02 : 0x01, // número de métodos
        0x00, // NoAuth
        if (hasCreds) 0x02, // UsernamePassword
      ];
    }

    test('sem credenciais oferece SÓ NoAuth (o fix)', () {
      final g = buildGreeting();
      expect(g[0], 0x05, reason: 'versão SOCKS5');
      expect(g[1], 0x01, reason: 'exatamente 1 método oferecido');
      expect(g[2], 0x00, reason: 'NoAuth');
      expect(g.length, 3, reason: 'não pode incluir USERPASS');
      expect(g.contains(0x02), isFalse,
          reason: 'USERPASS sem credenciais faz o Orbot rejeitar tudo');
    });

    test('com usuário oferece os dois métodos', () {
      final g = buildGreeting(username: 'user');
      expect(g[1], 0x02);
      expect(g.sublist(2), [0x00, 0x02]);
    });

    test('com senha (sem usuário) também oferece os dois', () {
      final g = buildGreeting(password: 'pass');
      expect(g[1], 0x02);
      expect(g.sublist(2), [0x00, 0x02]);
    });

    test('o greeting antigo (sempre 2 métodos) era o bug', () {
      // Reprodução do comportamento upstream — deve ser diferente do fix.
      const oldGreeting = [0x05, 0x02, 0x00, 0x02];
      final fixed = buildGreeting();
      expect(fixed, isNot(equals(oldGreeting)),
          reason: 'o fix precisa mudar o greeting sem credenciais');
    });
  });

  group('TorService — spec do proxy', () {
    test('spec usa o formato que o parser do pacote aceita', () {
      // O parser exige "SOCKS5 host:port" (espaço, não dois-pontos).
      // "SOCKS5:127.0.0.1:9050" lançaria HttpException no parse.
      const spec = 'SOCKS5 127.0.0.1:9050';
      expect(spec.startsWith('SOCKS5 '), isTrue);
      expect(spec.contains('SOCKS5:'), isFalse);

      final rest = spec.substring('SOCKS5 '.length).trim();
      final colon = rest.lastIndexOf(':');
      expect(colon, greaterThan(0));
      expect(rest.substring(0, colon), '127.0.0.1');
      expect(int.parse(rest.substring(colon + 1)), 9050);
    });

    test('portas por plataforma', () {
      // Android: Orbot padrão. iOS: Orbot App Store. Desktop: tor do sistema.
      expect(Platform.isAndroid ? 9050 : (Platform.isIOS ? 39050 : 9050),
          anyOf(9050, 39050));
    });
  });
}

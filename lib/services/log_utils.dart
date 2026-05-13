import 'package:flutter/foundation.dart';

/// v582: Buffer circular de logs em memória. Como `broLog` é silenciado em
/// release (não vai para logcat), perdemos visibilidade quando bugs aparecem
/// em produção. Este buffer mantém os últimos N broLog em RAM e pode ser
/// exportado pelo usuário via tela de diagnóstico (Configurações → Diagnóstico).
/// Não é persistido em disco — esvazia ao fechar o app, evitando trilha
/// de auditoria indesejada para informações sensíveis.
class BroLogBuffer {
  BroLogBuffer._();
  static final BroLogBuffer instance = BroLogBuffer._();

  static const int _maxEntries = 500;
  final List<String> _entries = [];

  void add(String message) {
    final ts = DateTime.now().toIso8601String();
    _entries.add('[$ts] $message');
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
  }

  /// Retorna uma cópia dos logs (mais antigo primeiro).
  List<String> snapshot() => List.unmodifiable(_entries);

  String toShareableString() => _entries.join('\n');

  void clear() => _entries.clear();
}

/// Wrapper de log que só imprime em modo debug ou profile.
/// Em release, nenhuma mensagem é emitida, evitando exposição de dados
/// sensíveis via adb logcat.
///
/// v582: Em release, AINDA registra no buffer em memória para que a tela
/// de Diagnóstico possa exibir os últimos eventos quando o usuário reportar
/// problemas. Buffer não persiste em disco.
void broLog(String message) {
  if (kDebugMode || kProfileMode) {
    debugPrint(message);
  }
  // Sempre registra no buffer (debug + release) para diagnóstico in-app.
  BroLogBuffer.instance.add(message);
}

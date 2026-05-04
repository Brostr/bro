import 'package:flutter/foundation.dart';

/// Wrapper de log que só imprime em modo debug ou profile.
/// Em release, nenhuma mensagem é emitida, evitando exposição de dados
/// sensíveis via adb logcat.
void broLog(String message) {
  if (kDebugMode || kProfileMode) {
    debugPrint(message);
  }
}

/// v615: Converte exceções técnicas em mensagens amigáveis para o usuário.
///
/// As telas mostravam `e.toString()` cru (ex.: "SocketException: Failed host
/// lookup ...", "TimeoutException after 0:00:15"), o que assusta o usuário e
/// vaza detalhes internos. Esta função mapeia os erros mais comuns para texto
/// curto e claro, sem alterar o log técnico (que continua via broLog).
String humanizeError(Object error) {
  final raw = error.toString();
  final lower = raw.toLowerCase();

  if (lower.contains('socketexception') ||
      lower.contains('failed host lookup') ||
      lower.contains('network is unreachable') ||
      lower.contains('connection refused') ||
      lower.contains('connection closed') ||
      lower.contains('connection reset')) {
    return 'Sem conexão com a internet. Verifique sua rede e tente novamente.';
  }

  if (lower.contains('timeoutexception') || lower.contains('timed out')) {
    return 'A operação demorou demais. Tente novamente em instantes.';
  }

  if (lower.contains('handshake') || lower.contains('certificate')) {
    return 'Falha de conexão segura. Tente novamente.';
  }

  if (lower.contains('insufficient') || lower.contains('saldo')) {
    return 'Saldo insuficiente para concluir a operação.';
  }

  if (lower.contains('401') ||
      lower.contains('unauthorized') ||
      lower.contains('nip-98') ||
      lower.contains('nip98')) {
    return 'Falha de autenticação. Tente novamente.';
  }

  if (lower.contains('429') || lower.contains('rate limit')) {
    return 'Muitas tentativas. Aguarde um momento e tente de novo.';
  }

  // Fallback: remover prefixos técnicos comuns para não assustar.
  var cleaned = raw
      .replaceFirst(RegExp(r'^Exception:\s*'), '')
      .replaceFirst(RegExp(r'^DioException.*?:\s*'), '')
      .trim();
  if (cleaned.isEmpty) {
    return 'Ocorreu um erro inesperado. Tente novamente.';
  }
  // Limitar tamanho para não estourar a UI.
  if (cleaned.length > 160) {
    cleaned = '${cleaned.substring(0, 157)}...';
  }
  return cleaned;
}

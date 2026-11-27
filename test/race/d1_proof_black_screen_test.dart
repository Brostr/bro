import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// D1 — comprovante "tela preta".
///
/// Causa raiz: `Image.memory(base64Decode(x))` avalia o `base64Decode` ANTES
/// de construir o widget. Um base64 truncado (NIP-44 de build antigo com
/// plaintext > 65535 bytes, fragmento de sync, marcador `[encrypted:...]`)
/// lançava `FormatException` e derrubava a tela inteira — o `errorBuilder`
/// nunca era chamado porque a exceção acontecia no argumento.
///
/// Estes testes travam o contrato do decodificador seguro: NUNCA lançar,
/// devolver null quando não dá para decodificar.
Uint8List? safeImageBytes(String? value) {
  if (value == null || value.isEmpty) return null;
  try {
    final raw = value.startsWith('data:image') ? value.split(',').last : value;
    final bytes = base64Decode(raw);
    if (bytes.length < 12) return null;
    return bytes;
  } catch (_) {
    return null;
  }
}

void main() {
  // JPEG mínimo válido (FF D8 FF ... ) com 16 bytes.
  final jpegBytes = Uint8List.fromList([
    0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46,
    0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01,
  ]);
  final jpegB64 = base64Encode(jpegBytes);

  test('base64 válido decodifica', () {
    final out = safeImageBytes(jpegB64);
    expect(out, isNotNull);
    expect(out!.length, jpegBytes.length);
  });

  test('data URI válido decodifica', () {
    final out = safeImageBytes('data:image/jpeg;base64,$jpegB64');
    expect(out, isNotNull);
    expect(out!.length, jpegBytes.length);
  });

  test('base64 truncado NÃO lança (era a tela preta)', () {
    // Corta no meio de um grupo de 4 — base64Decode lançaria FormatException.
    final truncated = jpegB64.substring(0, jpegB64.length - 3);
    expect(() => safeImageBytes(truncated), returnsNormally);
    expect(safeImageBytes(truncated), isNull);
  });

  test('marcador de criptografia NÃO lança', () {
    expect(() => safeImageBytes('[encrypted:nip44v2]'), returnsNormally);
    expect(safeImageBytes('[encrypted:nip44v2]'), isNull);
  });

  test('string vazia e null devolvem null', () {
    expect(safeImageBytes(''), isNull);
    expect(safeImageBytes(null), isNull);
  });

  test('base64 curto demais (fragmento de sync) devolve null', () {
    // Bug real 90800cdf: proofImage com 10 chars deixava a tela preta.
    final short = base64Encode(utf8.encode('abcdefghij'));
    expect(safeImageBytes(short), isNull);
  });

  test('caminho de arquivo local NÃO lança', () {
    expect(() => safeImageBytes('/data/user/0/app/cache/foto.jpg'), returnsNormally);
    expect(safeImageBytes('/data/user/0/app/cache/foto.jpg'), isNull);
  });

  test('base64 gigante (NIP-44 estourado) decodifica sem lançar', () {
    // 70 KB de bytes aleatórios → base64 ~93 KB. O NIP-44 v2 trunca em 65535,
    // mas o decodificador local não pode explodir por causa disso.
    final big = Uint8List.fromList(List<int>.generate(70000, (i) => i % 256));
    final bigB64 = base64Encode(big);
    expect(() => safeImageBytes(bigB64), returnsNormally);
    expect(safeImageBytes(bigB64)!.length, 70000);
  });
}

import 'package:flutter_test/flutter_test.dart';

/// D1b — comprovante não aparece mesmo com a prova disponível.
///
/// Dois bugs distintos, ambos reproduzidos em ordens reais:
///
/// ## Bug A — ordem 1c2dd29e: resultado bom sobrescrito por relay posterior
///
/// `fetchProofForOrder` percorre TODOS os relays e agrega. Um relay decifrava
/// (`found=true, encrypted=false`) e o relay seguinte, cujo evento não
/// decifrava, fazia `result['encrypted'] = true` — e a tela descartava a prova
/// boa por causa da condição `!encrypted`.
///
/// ## Bug B — ordem 2646d74f: merge assimétrico de metadata
///
/// `_buildReceiptCard` mesclava metadata local com a do OrderProvider, mas só
/// substituía quando o LOCAL era pior. Se o local tinha `[encrypted:nip44v2]`
/// e o provider tinha a imagem já decifrada, o marcador vencia.
void main() {
  group('Bug A — agregação de proof entre relays', () {
    /// Simula o acumulador de `fetchProofForOrder`.
    Map<String, dynamic> aggregate(List<Map<String, dynamic>> relayResults) {
      final result = <String, dynamic>{'proofImage': null, 'encrypted': false};
      for (final r in relayResults) {
        final proof = r['proofImage'] as String?;
        final enc = r['proofImage_nip44'] as String?;
        if (proof != null && proof.isNotEmpty && !proof.startsWith('[encrypted:')) {
          result['proofImage'] = proof;
          result['encrypted'] = false;
        } else if (result['proofImage'] != null) {
          // v863 FIX: não sobrescrever prova já obtida
          continue;
        } else if (enc != null && enc.isNotEmpty) {
          result['encrypted'] = true;
        }
      }
      return result;
    }

    test('relay que decifra + relay que não decifra = prova preservada', () {
      final out = aggregate([
        {'proofImage': 'BASE64_DA_IMAGEM', 'encrypted': false},
        {'proofImage': null, 'proofImage_nip44': 'CIFRADO', 'encrypted': true},
      ]);
      expect(out['proofImage'], 'BASE64_DA_IMAGEM',
          reason: 'o relay seguinte não pode zerar a prova boa');
      expect(out['encrypted'], isFalse);
    });

    test('ordem inversa também preserva', () {
      final out = aggregate([
        {'proofImage': null, 'proofImage_nip44': 'CIFRADO', 'encrypted': true},
        {'proofImage': 'BASE64_DA_IMAGEM', 'encrypted': false},
      ]);
      expect(out['proofImage'], 'BASE64_DA_IMAGEM');
      expect(out['encrypted'], isFalse);
    });

    test('nenhum relay decifrou = encrypted true, sem prova', () {
      final out = aggregate([
        {'proofImage': null, 'proofImage_nip44': 'CIFRADO', 'encrypted': true},
        {'proofImage': null, 'proofImage_nip44': 'CIFRADO2', 'encrypted': true},
      ]);
      expect(out['proofImage'], isNull);
      expect(out['encrypted'], isTrue);
    });

    test('marcador [encrypted:] não conta como prova', () {
      final out = aggregate([
        {'proofImage': '[encrypted:nip44v2]', 'encrypted': false},
      ]);
      expect(out['proofImage'], isNull);
    });
  });

  group('Bug B — merge de metadata local × OrderProvider', () {
    /// Reproduz a regra do merge em `_buildReceiptCard`.
    Map<String, dynamic> merge(
      Map<String, dynamic> local,
      Map<String, dynamic> provider,
    ) {
      final metadata = Map<String, dynamic>.from(local);
      for (final key in provider.keys) {
        final existingVal = metadata[key];
        final providerVal = provider[key];
        final existingStr = existingVal is String ? existingVal : null;
        final providerStr = providerVal is String ? providerVal : null;
        final existingIsMarker = existingStr == null ||
            existingStr.isEmpty ||
            existingStr.startsWith('[encrypted:');
        final providerIsMarker = providerStr == null ||
            providerStr.isEmpty ||
            providerStr.startsWith('[encrypted:');
        final providerIsBetter = !providerIsMarker &&
            (existingIsMarker ||
                (key == 'proofImage' &&
                    existingStr != null &&
                    providerStr != null &&
                    providerStr.length > existingStr.length * 2));
        if (providerIsBetter && providerVal != null) {
          metadata[key] = providerVal;
        }
      }
      return metadata;
    }

    test('local com marcador + provider decifrado = provider vence', () {
      final out = merge(
        {'proofImage': '[encrypted:nip44v2]'},
        {'proofImage': 'BASE64_DECIFRADO_LONGO'},
      );
      expect(out['proofImage'], 'BASE64_DECIFRADO_LONGO',
          reason: 'marcador de criptografia não pode vencer a imagem real');
    });

    test('local ausente + provider presente = provider vence', () {
      final out = merge({}, {'proofImage': 'BASE64'});
      expect(out['proofImage'], 'BASE64');
    });

    test('local bom + provider com marcador = local preservado', () {
      final out = merge(
        {'proofImage': 'BASE64_BOM'},
        {'proofImage': '[encrypted:nip44v2]'},
      );
      expect(out['proofImage'], 'BASE64_BOM');
    });

    test('local truncado + provider longo = provider vence', () {
      final out = merge(
        {'proofImage': 'abc'},
        {'proofImage': 'A' * 5000},
      );
      expect(out['proofImage'], 'A' * 5000);
    });

    test('local bom + provider igual = local preservado (sem churn)', () {
      const img = 'BASE64_IGUAL';
      final out = merge({'proofImage': img}, {'proofImage': img});
      expect(out['proofImage'], img);
    });

    test('outros campos seguem a regra de marcador', () {
      final out = merge(
        {'paymentProof': '[encrypted:nip44v2]'},
        {'paymentProof': 'BASE64_REAL'},
      );
      expect(out['paymentProof'], 'BASE64_REAL');
    });
  });
}

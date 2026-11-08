import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bro_app/config.dart';
import 'package:bro_app/services/input_validation_service.dart';

void main() {
  final validator = InputValidationService();
  // Network is always explicit so results do not depend on AppConfig.
  ValidationResult onMainnet(String address) =>
      validator.validateBitcoinAddress(address, useMainnet: true);
  ValidationResult onTestnet(String address) =>
      validator.validateBitcoinAddress(address, useMainnet: false);

  group('Bitcoin address validation', () {
    for (final version in [0x00, 0x05]) {
      for (final hashLength in [0, 1, 19, 20, 21]) {
        test('Base58 version $version requires 20 hash bytes, got $hashLength',
            () {
          final address = base58Check(version, hashLength);
          // Stay under the 35-char guard so the decoded length is what decides.
          expect(address.length, lessThanOrEqualTo(35));
          final result = onMainnet(address);
          expect(result.isValid, hashLength == 20);
          if (hashLength != 20) {
            expect(result.error, 'Endereço Bitcoin inválido');
          }
        });
      }
    }

    test('rejects Base58 with unknown version byte on both networks', () {
      final address = base58Check(0x30, 20);
      expect(onMainnet(address).isValid, isFalse);
      expect(onTestnet(address).isValid, isFalse);
    });

    for (final entry in {0x6f: 'p2pkh', 0xc4: 'p2sh'}.entries) {
      test('testnet Base58 ${entry.value} is accepted only on testnet', () {
        final address = base58Check(entry.key, 20);
        final allowed = onTestnet(address);
        expect(allowed.isValid, isTrue);
        expect(allowed.type, entry.value);
        expect(allowed.sanitizedValue, address);
        final denied = onMainnet(address);
        expect(denied.isValid, isFalse);
        expect(denied.error, 'Endereço de testnet não aceito');
      });
    }

    for (final entry in {0x00: 'p2pkh', 0x05: 'p2sh'}.entries) {
      test('mainnet Base58 ${entry.value} is accepted only on mainnet', () {
        final address = base58Check(entry.key, 20);
        expect(onMainnet(address).isValid, isTrue);
        expect(onMainnet(address).type, entry.value);
        final denied = onTestnet(address);
        expect(denied.isValid, isFalse);
        expect(denied.error, 'Endereço de mainnet não aceito');
      });
    }

    test('segwit hrp must match the configured network exactly', () {
      const testnet =
          'tb1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3q0sl5k7';
      const mainnet = 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4';
      expect(onTestnet(testnet).isValid, isTrue);
      expect(onMainnet(testnet).isValid, isFalse);
      expect(onMainnet(testnet).error, 'Endereço de testnet não aceito');
      expect(onMainnet(mainnet).isValid, isTrue);
      expect(onTestnet(mainnet).isValid, isFalse);
      expect(onTestnet(mainnet).error, 'Endereço de mainnet não aceito');
    });

    test('default policy follows AppConfig.useMainnet only', () {
      final mainnet = base58Check(0x00, 20);
      final testnet = base58Check(0x6f, 20);
      expect(validator.validateBitcoinAddress(mainnet).isValid,
          AppConfig.useMainnet);
      expect(validator.validateBitcoinAddress(testnet).isValid,
          !AppConfig.useMainnet);
    });

    test('accepts valid mainnet segwit v0 bech32 addresses', () {
      final lower = onMainnet('bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4');
      expect(lower.isValid, isTrue);
      expect(lower.type, 'bech32');

      final upper = onMainnet('BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4');
      expect(upper.isValid, isTrue);
      expect(upper.sanitizedValue, 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4');

      final p2wsh = onMainnet(
        'bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3',
      );
      expect(p2wsh.isValid, isTrue);
      expect(p2wsh.type, 'bech32');
    });

    test('accepts valid mainnet segwit v1 bech32m address', () {
      final result = onMainnet(
        'bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0',
      );
      expect(result.isValid, isTrue);
      expect(result.type, 'bech32m');
    });

    // BIP350 valid testnet vectors (v0 P2WSH, v1 P2TR).
    for (final address in [
      'tb1qqqqqp399et2xygdj5xreqhjjvcmzhxw4aywxecjdzew6hylgvsesrxh6hy',
      'tb1pqqqqp399et2xygdj5xreqhjjvcmzhxw4aywxecjdzew6hylgvsesf3hn0c',
    ]) {
      test('accepts BIP350 testnet vector on testnet: $address', () {
        expect(onTestnet(address).isValid, isTrue);
      });
    }

    // BIP350-valid encodings that a withdrawal must still refuse:
    // v1 with a 40-byte program, v16 and v2 future versions.
    for (final address in [
      'bc1pw508d6qejxtdg4y5r3zarvary0c5xw7kw508d6qejxtdg4y5r3zarvary0c5xw7kt5nd6y',
      'BC1SW50QGDZ25J',
      'bc1zw508d6qejxtdg4y5r3zarvaryvaxxpcs',
    ]) {
      test('rejects non-spendable witness program: $address', () {
        final result = onMainnet(address);
        expect(result.isValid, isFalse);
        expect(result.error, 'Endereço Bitcoin inválido');
      });
    }

    for (final hrp in ['bc', 'tb']) {
      ValidationResult check(String address) =>
          hrp == 'bc' ? onMainnet(address) : onTestnet(address);

      for (final c in [(0, 20), (0, 32), (1, 32)]) {
        test('accepts $hrp v${c.$1} program of ${c.$2} bytes', () {
          final result = check(segwit(hrp, c.$1, c.$2));
          expect(result.isValid, isTrue);
          expect(result.type, c.$1 == 0 ? 'bech32' : 'bech32m');
        });
      }

      for (final c in [
        (0, 19),
        (0, 21),
        (0, 33),
        (1, 20),
        (1, 31),
        (1, 33),
        (1, 40),
        for (var v = 2; v <= 16; v++) (v, 32),
      ]) {
        test('rejects $hrp v${c.$1} program of ${c.$2} bytes', () {
          final result = check(segwit(hrp, c.$1, c.$2));
          expect(result.isValid, isFalse);
          expect(result.error, 'Endereço Bitcoin inválido');
        });
      }
    }

    test('accepts valid mainnet legacy and p2sh base58check addresses', () {
      final legacy = onMainnet('1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa');
      expect(legacy.isValid, isTrue);
      expect(legacy.type, 'p2pkh');

      final p2sh = onMainnet('3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy');
      expect(p2sh.isValid, isTrue);
      expect(p2sh.type, 'p2sh');
    });

    // BIP350 invalid-encoding vectors: checksum valid for the wrong variant.
    // https://github.com/bitcoin/bips/blob/master/bip-0350.mediawiki
    for (final address in [
      'bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqh2y7hd',
      'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kemeawh',
    ]) {
      test('rejects wrong witness checksum encoding: $address', () {
        expect(onMainnet(address).isValid, isFalse);
      });
    }

    test('rejects bech32 address with invalid checksum', () {
      final result = onMainnet('bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5');
      expect(result.isValid, isFalse);
      expect(result.error, contains('Checksum'));
    });

    test('rejects base58 address with invalid checksum', () {
      final result = onMainnet('1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb');
      expect(result.isValid, isFalse);
      expect(result.error, contains('Checksum'));
    });

    test('rejects mixed case bech32 addresses', () {
      final result = onMainnet('bc1QW508D6qejxtdg4y5r3zarvary0c5xw7kv8f3t4');
      expect(result.isValid, isFalse);
    });

    test('rejects bech32 strings with a character outside the alphabet', () {
      // 'o' is not in the bech32 charset; rejected before checksum.
      final result = onMainnet('bc1ow508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4');
      expect(result.isValid, isFalse);
      expect(result.error, 'Endereço Bitcoin inválido');
    });

    test('rejects empty and whitespace-only strings', () {
      expect(onMainnet('').isValid, isFalse);
      expect(onMainnet('   ').isValid, isFalse);
    });
  });
}

// Construct checksummed payloads independently of the validator.
String base58Check(int version, int hashLength) {
  const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  final payload = [version, ...List<int>.filled(hashLength, 0x42)];
  final bytes = [
    ...payload,
    ...sha256.convert(sha256.convert(payload).bytes).bytes.take(4)
  ];
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  var encoded = '';
  while (value > BigInt.zero) {
    encoded = alphabet[(value % BigInt.from(58)).toInt()] + encoded;
    value ~/= BigInt.from(58);
  }
  return '${'1' * bytes.takeWhile((byte) => byte == 0).length}$encoded';
}

// BIP173/BIP350 encoder: v0 uses bech32, v1+ uses bech32m, so vectors are
// correctly checksummed and can only fail on witness policy.
String segwit(String hrp, int version, int programLength) {
  const charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
  final data = <int>[version];
  var acc = 0;
  var bits = 0;
  for (final byte in List<int>.filled(programLength, 0x42)) {
    acc = ((acc << 8) | byte) & 0xfff;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      data.add((acc >> bits) & 31);
    }
  }
  if (bits > 0) data.add((acc << (5 - bits)) & 31);

  int polymod(List<int> values) {
    const gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
    var chk = 1;
    for (final v in values) {
      final top = chk >> 25;
      chk = ((chk & 0x1ffffff) << 5) ^ v;
      for (var i = 0; i < 5; i++) {
        if (((top >> i) & 1) == 1) chk ^= gen[i];
      }
    }
    return chk;
  }

  final hrpExpanded = [
    ...hrp.codeUnits.map((x) => x >> 5),
    0,
    ...hrp.codeUnits.map((x) => x & 31),
  ];
  final mod = polymod([...hrpExpanded, ...data, 0, 0, 0, 0, 0, 0]) ^
      (version == 0 ? 1 : 0x2bc830a3);
  final checksum = [for (var i = 0; i < 6; i++) (mod >> (5 * (5 - i))) & 31];
  return '${hrp}1${[...data, ...checksum].map((d) => charset[d]).join()}';
}

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bro_app/services/input_validation_service.dart';

void main() {
  final validator = InputValidationService();

  group('Bitcoin address validation', () {
    for (final version in [0x00, 0x05]) {
      for (final hashLength in [0, 19, 20, 21, 70]) {
        test('Base58 version $version requires 20 hash bytes, got $hashLength',
            () {
          final address = base58Check(version, hashLength);
          expect(validator.validateBitcoinAddress(address).isValid,
              hashLength == 20);
        });
      }
    }
    for (final entry in {0x6f: 'p2pkh', 0xc4: 'p2sh'}.entries) {
      test('testnet Base58 ${entry.value} follows explicit network policy', () {
        final address = base58Check(entry.key, 20);
        final allowed =
            validator.validateBitcoinAddress(address, allowTestnet: true);
        expect(allowed.isValid, isTrue);
        expect(allowed.type, entry.value);
        expect(allowed.sanitizedValue, address);
        final denied =
            validator.validateBitcoinAddress(address, allowTestnet: false);
        expect(denied.isValid, isFalse);
        expect(denied.error, 'Endereço de testnet não aceito');
      });
    }
    test('testnet segwit follows the same explicit network policy', () {
      const address =
          'tb1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3q0sl5k7';
      expect(
          validator.validateBitcoinAddress(address, allowTestnet: true).isValid,
          isTrue);
      expect(
          validator
              .validateBitcoinAddress(address, allowTestnet: false)
              .isValid,
          isFalse);
    });
    test('accepts valid mainnet segwit v0 bech32 addresses', () {
      final lower = validator.validateBitcoinAddress(
        'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4',
      );
      expect(lower.isValid, isTrue);
      expect(lower.type, 'bech32');

      final upper = validator.validateBitcoinAddress(
        'BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4',
      );
      expect(upper.isValid, isTrue);
      expect(upper.sanitizedValue, 'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4');
    });

    test('accepts valid mainnet segwit v1 bech32m address', () {
      final result = validator.validateBitcoinAddress(
        'bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0',
      );
      expect(result.isValid, isTrue);
      expect(result.type, 'bech32m');
    });

    test('accepts valid mainnet legacy and p2sh base58check addresses', () {
      final legacy = validator.validateBitcoinAddress(
        '1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa',
      );
      expect(legacy.isValid, isTrue);
      expect(legacy.type, 'p2pkh');

      final p2sh = validator.validateBitcoinAddress(
        '3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy',
      );
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
        expect(validator.validateBitcoinAddress(address).isValid, isFalse);
      });
    }

    test('rejects bech32 address with invalid checksum', () {
      final result = validator.validateBitcoinAddress(
        'bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5',
      );
      expect(result.isValid, isFalse);
      expect(result.error, contains('Checksum'));
    });

    test('rejects base58 address with invalid checksum', () {
      final result = validator.validateBitcoinAddress(
        '1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb',
      );
      expect(result.isValid, isFalse);
      expect(result.error, contains('Checksum'));
    });

    test('rejects mixed case bech32 addresses', () {
      final result = validator.validateBitcoinAddress(
        'bc1QW508D6qejxtdg4y5r3zarvary0c5xw7kv8f3t4',
      );
      expect(result.isValid, isFalse);
    });

    test('rejects bech32 strings with invalid alphabet even if length matches', () {
      final result = validator.validateBitcoinAddress(
        'bc1zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz',
      );
      expect(result.isValid, isFalse);
    });

    test('rejects testnet addresses while app is configured for mainnet', () {
      final bech32 = validator.validateBitcoinAddress(
        'tb1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3q0sl5k7',
      );
      expect(bech32.isValid, isFalse);
      expect(bech32.error, 'Endereço de testnet não aceito');

      final legacy = validator.validateBitcoinAddress(
        'mipcBbFg9gMiCh81Kj8tqqdgoZub1ZJRfn',
      );
      expect(legacy.isValid, isFalse);
      expect(legacy.error, 'Endereço de testnet não aceito');

      final p2sh = validator.validateBitcoinAddress(
        '2N2JD6wb56AfK4tfmM6PwdVmoYk2dCKf4Br',
      );
      expect(p2sh.isValid, isFalse);
      expect(p2sh.error, 'Endereço de testnet não aceito');
    });

    test('rejects empty and whitespace-only strings', () {
      expect(validator.validateBitcoinAddress('').isValid, isFalse);
      expect(validator.validateBitcoinAddress('   ').isValid, isFalse);
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

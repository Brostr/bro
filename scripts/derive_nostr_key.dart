// Standalone NIP-06 derivation, identical algorithm to lib/services/nip06_service.dart
// Reads the mnemonic ONLY from the BRO_SEED environment variable (never argv),
// so the secret never appears on a command line.
//
// Output:
//   PUBKEY=<64-hex x-only public key>      (always printed; public, safe)
//   SEC=<64-hex private key>               (printed ONLY if BRO_EMIT_SEC=1)
//
// Run from the project root:  dart run scripts/derive_nostr_key.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:bip39/bip39.dart' as bip39;
import 'package:pointycastle/export.dart';
import 'package:convert/convert.dart';

class _ExtendedKey {
  final Uint8List privateKey;
  final Uint8List chainCode;
  _ExtendedKey({required this.privateKey, required this.chainCode});
}

BigInt _bytesToBigInt(Uint8List bytes) =>
    BigInt.parse(hex.encode(bytes), radix: 16);

Uint8List _bigIntToBytes(BigInt number, int length) {
  final hexStr = number.toRadixString(16).padLeft(length * 2, '0');
  return Uint8List.fromList(hex.decode(hexStr));
}

Uint8List _getCompressedPublicKey(Uint8List privateKey) {
  final privateInt = _bytesToBigInt(privateKey);
  final ecDomain = ECDomainParameters('secp256k1');
  final publicPoint = ecDomain.G * privateInt;
  final x = publicPoint!.x!.toBigInteger()!;
  final y = publicPoint.y!.toBigInteger()!;
  final compressed = Uint8List(33);
  compressed[0] = y.isOdd ? 0x03 : 0x02;
  compressed.setRange(1, 33, _bigIntToBytes(x, 32));
  return compressed;
}

_ExtendedKey _deriveMasterKey(Uint8List seed) {
  final hmac = HMac(SHA512Digest(), 128);
  hmac.init(KeyParameter(utf8.encode('Bitcoin seed') as Uint8List));
  final output = Uint8List(64);
  hmac.update(seed, 0, seed.length);
  hmac.doFinal(output, 0);
  return _ExtendedKey(
    privateKey: output.sublist(0, 32),
    chainCode: output.sublist(32, 64),
  );
}

_ExtendedKey _deriveChild(_ExtendedKey parent, int index) {
  final hmac = HMac(SHA512Digest(), 128);
  hmac.init(KeyParameter(parent.chainCode));
  final data = Uint8List(37);
  if (index >= 0x80000000) {
    data[0] = 0x00;
    data.setRange(1, 33, parent.privateKey);
  } else {
    data.setRange(0, 33, _getCompressedPublicKey(parent.privateKey));
  }
  data[33] = (index >> 24) & 0xFF;
  data[34] = (index >> 16) & 0xFF;
  data[35] = (index >> 8) & 0xFF;
  data[36] = index & 0xFF;
  final output = Uint8List(64);
  hmac.update(data, 0, data.length);
  hmac.doFinal(output, 0);
  final parentInt = _bytesToBigInt(parent.privateKey);
  final derivedInt = _bytesToBigInt(output.sublist(0, 32));
  final ecDomain = ECDomainParameters('secp256k1');
  final newPrivateInt = (parentInt + derivedInt) % ecDomain.n;
  return _ExtendedKey(
    privateKey: _bigIntToBytes(newPrivateInt, 32),
    chainCode: output.sublist(32, 64),
  );
}

String deriveNostrPrivateKey(String mnemonic, {String passphrase = ''}) {
  final seed = Uint8List.fromList(
      bip39.mnemonicToSeed(mnemonic, passphrase: passphrase));
  var key = _deriveMasterKey(seed);
  key = _deriveChild(key, 0x8000002C); // 44'
  key = _deriveChild(key, 0x800004D5); // 1237'
  key = _deriveChild(key, 0x80000000); // 0'
  key = _deriveChild(key, 0); // 0
  key = _deriveChild(key, 0); // 0
  return hex.encode(key.privateKey);
}

String derivePublicKey(String privateKeyHex) {
  final privateKeyInt = BigInt.parse(privateKeyHex, radix: 16);
  final ecDomain = ECDomainParameters('secp256k1');
  final publicKeyPoint = ecDomain.G * privateKeyInt;
  final xCoord = publicKeyPoint!.x!.toBigInteger()!;
  return xCoord.toRadixString(16).padLeft(64, '0');
}

// ---- Bech32 (BIP-173) encoding for nsec ----
const String _bech32Charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

List<int> _convertBits(List<int> data, int from, int to, bool pad) {
  var acc = 0;
  var bits = 0;
  final ret = <int>[];
  final maxv = (1 << to) - 1;
  for (final value in data) {
    acc = (acc << from) | value;
    bits += from;
    while (bits >= to) {
      bits -= to;
      ret.add((acc >> bits) & maxv);
    }
  }
  if (pad && bits > 0) {
    ret.add((acc << (to - bits)) & maxv);
  }
  return ret;
}

int _polymod(List<int> values) {
  const gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  var chk = 1;
  for (final v in values) {
    final b = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (var i = 0; i < 5; i++) {
      if (((b >> i) & 1) != 0) chk ^= gen[i];
    }
  }
  return chk;
}

List<int> _hrpExpand(String hrp) {
  final ret = <int>[];
  for (var i = 0; i < hrp.length; i++) {
    ret.add(hrp.codeUnitAt(i) >> 5);
  }
  ret.add(0);
  for (var i = 0; i < hrp.length; i++) {
    ret.add(hrp.codeUnitAt(i) & 31);
  }
  return ret;
}

String bech32Encode(String hrp, List<int> data) {
  final values = [..._hrpExpand(hrp), ...data];
  final polymod = _polymod([...values, 0, 0, 0, 0, 0, 0]) ^ 1;
  final checksum = <int>[];
  for (var i = 0; i < 6; i++) {
    checksum.add((polymod >> (5 * (5 - i))) & 31);
  }
  final combined = [...data, ...checksum];
  final sb = StringBuffer('${hrp}1');
  for (final d in combined) {
    sb.write(_bech32Charset[d]);
  }
  return sb.toString();
}

String hexToNsec(String hexKey) {
  final bytes = hex.decode(hexKey);
  final data = _convertBits(bytes, 8, 5, true);
  return bech32Encode('nsec', data);
}

void main() {
  var mnemonic = Platform.environment['BRO_SEED'] ?? '';
  // normalize: collapse whitespace, lowercase
  mnemonic = mnemonic.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  if (mnemonic.isEmpty) {
    stderr.writeln('ERROR: BRO_SEED env var is empty');
    exit(2);
  }
  if (Platform.environment['BRO_SKIP_VALIDATE'] != '1' &&
      !bip39.validateMnemonic(mnemonic)) {
    stderr.writeln('ERROR: invalid BIP-39 mnemonic');
    exit(3);
  }
  final passphrase = Platform.environment['BRO_PASSPHRASE'] ?? '';
  final sec = deriveNostrPrivateKey(mnemonic, passphrase: passphrase);
  final pub = derivePublicKey(sec);
  stdout.writeln('PUBKEY=$pub');
  if (Platform.environment['BRO_EMIT_SEC'] == '1') {
    stdout.writeln('SEC=$sec');
    stdout.writeln('NSEC=${hexToNsec(sec)}');
  }
}

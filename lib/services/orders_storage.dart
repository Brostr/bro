/// v578 (Phase 3): Encryption-at-rest wrapper around the
/// `orders_<pubkey>` SharedPreferences blob.
///
/// Threat: SharedPreferences XML lives at
/// `/data/data/app.bro.mobile/shared_prefs/...xml` (or iOS plist). It is
/// readable by:
///  - adb backup (when user enables it / on rooted devices)
///  - local malware with READ_EXTERNAL_STORAGE on legacy devices
///  - device-state extraction tools
///  - leaked Google Drive / iTunes backups
///
/// Plaintext orders include billCode (PIX), counterparty pubkeys, amounts,
/// and proof-of-payment image keys. Encrypting at rest with a key held in
/// FlutterSecureStorage (Keystore-backed on Android, Keychain on iOS)
/// raises the bar significantly: an attacker now needs both the prefs
/// file AND keystore extraction (rooted device or known device exploit),
/// not just the prefs file.
///
/// Design:
///  - One symmetric 32-byte key per install, generated on first use,
///    persisted in FlutterSecureStorage under `orders_at_rest_key_v1`.
///  - Crypto: ChaCha20 (RFC 7539) + HMAC-SHA256, same primitives already
///    used by Nip44Service. No new deps.
///  - On-disk format: `enc1:` prefix + base64( nonce(12) || ciphertext || hmac(32) )
///  - Plaintext detection: legacy values start with `[` (JSON array) — base64
///    alphabet never contains `[`. So legacy values pass through on read,
///    and the very next save re-writes encrypted.
///  - Decrypt failure → return null (treated as "no local cache"). Caller
///    re-syncs from Nostr. Never overwrites the ciphertext on failure so
///    a key-rotation scenario can be debugged.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'log_utils.dart';

class OrdersStorage {
  static const String _marker = 'enc1:';
  static const String _keyAlias = 'orders_at_rest_key_v1';

  // Same FlutterSecureStorage configuration as StorageService so the key
  // lives in EncryptedSharedPreferences (Android) / Keychain (iOS).
  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  // Cached key bytes per isolate (avoid platform channel hit on every read).
  static Uint8List? _cachedKey;

  /// Returns the prefs key for a given user pubkey.
  static String prefsKey(String pubkey) => 'orders_$pubkey';

  /// Read and decrypt the orders blob. Returns plaintext JSON, or null
  /// if absent / undecryptable.
  static Future<String?> read(SharedPreferences prefs, String pubkey) async {
    final raw = prefs.getString(prefsKey(pubkey));
    if (raw == null || raw.isEmpty) return null;

    // Legacy plaintext (pre-v578). Pass through; next write re-encrypts.
    if (!raw.startsWith(_marker)) return raw;

    try {
      final key = await _getKey();
      final body = raw.substring(_marker.length);
      final blob = base64.decode(body);
      if (blob.length < 12 + 32) {
        broLog('[OrdersStorage] blob too short, returning null');
        return null;
      }
      final nonce = blob.sublist(0, 12);
      final ct = blob.sublist(12, blob.length - 32);
      final mac = blob.sublist(blob.length - 32);

      // Verify HMAC first (encrypt-then-MAC).
      final expectedMac = _hmac(key, nonce, ct);
      if (!_constantTimeEq(mac, expectedMac)) {
        broLog('[OrdersStorage] HMAC mismatch, refusing to decrypt');
        return null;
      }

      final pt = Uint8List(ct.length);
      ChaCha7539Engine()
        ..init(false, ParametersWithIV(KeyParameter(key), nonce))
        ..processBytes(ct, 0, ct.length, pt, 0);
      return utf8.decode(pt);
    } catch (e) {
      broLog('[OrdersStorage] decrypt failed: $e');
      return null;
    }
  }

  /// Encrypt and persist the orders blob.
  static Future<bool> write(
    SharedPreferences prefs,
    String pubkey,
    String plaintextJson,
  ) async {
    try {
      final key = await _getKey();
      final nonce = _randomBytes(12);
      final pt = Uint8List.fromList(utf8.encode(plaintextJson));
      final ct = Uint8List(pt.length);
      ChaCha7539Engine()
        ..init(true, ParametersWithIV(KeyParameter(key), nonce))
        ..processBytes(pt, 0, pt.length, ct, 0);
      final mac = _hmac(key, nonce, ct);

      final blob = Uint8List(nonce.length + ct.length + mac.length);
      blob.setRange(0, nonce.length, nonce);
      blob.setRange(nonce.length, nonce.length + ct.length, ct);
      blob.setRange(nonce.length + ct.length, blob.length, mac);

      final encoded = '$_marker${base64.encode(blob)}';
      return await prefs.setString(prefsKey(pubkey), encoded);
    } catch (e) {
      broLog('[OrdersStorage] encrypt failed, falling back to plaintext: $e');
      // Defensive fallback: plaintext write so we never lose data because
      // of a transient secure-storage error. Worst case = same security
      // posture as pre-v578.
      return await prefs.setString(prefsKey(pubkey), plaintextJson);
    }
  }

  /// Test-only / migration helper: drop cached key (next call re-reads
  /// from secure storage).
  static void resetCacheForTesting() {
    _cachedKey = null;
  }

  // ---- internals ----

  static Future<Uint8List> _getKey() async {
    final cached = _cachedKey;
    if (cached != null) return cached;
    String? hex = await _secure.read(key: _keyAlias);
    if (hex == null || hex.length != 64) {
      final fresh = _randomBytes(32);
      hex = _toHex(fresh);
      await _secure.write(key: _keyAlias, value: hex);
      _cachedKey = fresh;
      return fresh;
    }
    final bytes = _fromHex(hex);
    _cachedKey = bytes;
    return bytes;
  }

  static Uint8List _hmac(Uint8List key, Uint8List nonce, Uint8List ct) {
    // HMAC over (nonce || ciphertext) — same construction NIP-44 uses.
    final h = Hmac(sha256, key);
    final input = Uint8List(nonce.length + ct.length);
    input.setRange(0, nonce.length, nonce);
    input.setRange(nonce.length, input.length, ct);
    return Uint8List.fromList(h.convert(input).bytes);
  }

  static bool _constantTimeEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static final math.Random _rng = math.Random.secure();

  static Uint8List _randomBytes(int n) {
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }

  static String _toHex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static Uint8List _fromHex(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

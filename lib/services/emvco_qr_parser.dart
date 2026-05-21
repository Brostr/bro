/// EMVCo Merchant Presented Mode QR parser
/// ----------------------------------------------------------------------
/// Used by: PIX (BR) · CoDi (MX) · PromptPay (TH) · Transferencias 3.0 (AR)
///          · Bre-B (CO) · UPI in QR form (IN)
///
/// All these QR codes share the EMVCo TLV layout (ID-LL-Value) defined in
/// EMV QRCPS v1.1. We parse the canonical top-level fields:
///   - 53 : currency numeric code (ISO 4217)
///   - 54 : transaction amount (string)
///   - 58 : country code (ISO 3166-1 alpha-2)
///   - 59 : merchant name
///   - 60 : merchant city
///   - 63 : CRC16 (validated)
///
/// The parser is intentionally tolerant: malformed nested templates do not
/// abort parsing of the rest of the payload. Only CRC failure rejects the
/// whole code.
///
/// v588: introduced for the multi-country provider mode rollout.
library;


/// Result of parsing an EMVCo QR string.
class EmvcoResult {
  /// ISO 3166-1 alpha-2 country code (e.g. "BR", "MX", "TH", "AR", "CO").
  final String countryCode;

  /// ISO 4217 currency code (e.g. "BRL", "MXN", "THB").
  final String currencyCode;

  /// Numeric currency code from EMVCo field 53 (e.g. "986" for BRL).
  final String currencyNumeric;

  /// Transaction amount in major currency units, or null if not present.
  final double? amount;

  /// Merchant name (field 59), trimmed. May be empty.
  final String merchantName;

  /// Merchant city (field 60), trimmed. May be empty.
  final String merchantCity;

  /// Mapped Bro `billType` identifier (e.g. 'pix', 'mx_codi', 'th_promptpay').
  final String billType;

  /// Raw parsed top-level TLV fields (id → value), useful for debugging.
  final Map<String, String> rawFields;

  EmvcoResult({
    required this.countryCode,
    required this.currencyCode,
    required this.currencyNumeric,
    required this.amount,
    required this.merchantName,
    required this.merchantCity,
    required this.billType,
    required this.rawFields,
  });

  Map<String, dynamic> toMap() => {
        'countryCode': countryCode,
        'currencyCode': currencyCode,
        'currencyNumeric': currencyNumeric,
        'amount': amount,
        'merchantName': merchantName,
        'merchantCity': merchantCity,
        'billType': billType,
      };

  @override
  String toString() => 'EmvcoResult($billType, $countryCode/$currencyCode, '
      'amount=$amount, merchant="$merchantName", city="$merchantCity")';
}

class EmvcoQrParser {
  /// Heuristic: a payload that starts with "000201" (Payload Format Indicator
  /// id=00, len=02, value="01") AND consists of printable ASCII is a candidate
  /// EMVCo QR. Length filter avoids matching short prefixes accidentally.
  static bool looksLikeEmvco(String code) {
    final s = code.trim();
    if (s.length < 30) return false;
    if (!s.startsWith('000201')) return false;
    // Field 63 (CRC) is always at the END as "6304XXXX", so a valid EMVCo
    // payload has at least one occurrence in the last 8 chars.
    final tail = s.substring(s.length - 8);
    if (!tail.startsWith('6304')) return false;
    return true;
  }

  /// Parses an EMVCo QR string. Returns null if structurally invalid or the
  /// CRC fails. Caller should fall back to country-specific parsers for the
  /// fields it cares about (e.g. PIX `26` template).
  static EmvcoResult? parse(String code) {
    final s = code.trim();
    if (!looksLikeEmvco(s)) return null;

    // CRC check first — protects all subsequent parsing.
    if (!_verifyCrc(s)) {
      // Caller can log; we keep this module dependency-free.
      return null;
    }

    final fields = _parseTlv(s);
    if (fields == null) return null;

    final currencyNumeric = (fields['53'] ?? '').trim();
    final countryCode = (fields['58'] ?? '').trim().toUpperCase();
    final amountStr = (fields['54'] ?? '').trim();
    final merchantName = (fields['59'] ?? '').trim();
    final merchantCity = (fields['60'] ?? '').trim();

    double? amount;
    if (amountStr.isNotEmpty) {
      amount = double.tryParse(amountStr);
    }

    final currencyCode = _currencyFromNumeric(currencyNumeric);
    final billType = _billTypeFor(countryCode, currencyNumeric);

    return EmvcoResult(
      countryCode: countryCode,
      currencyCode: currencyCode,
      currencyNumeric: currencyNumeric,
      amount: amount,
      merchantName: merchantName,
      merchantCity: merchantCity,
      billType: billType,
      rawFields: fields,
    );
  }

  // ── Internals ───────────────────────────────────────────────────────

  /// Parses the top-level TLV chain. Returns null on structural error
  /// (e.g. a length that runs past the end of the string).
  static Map<String, String>? _parseTlv(String s) {
    final result = <String, String>{};
    var i = 0;
    final n = s.length;
    while (i < n) {
      if (i + 4 > n) return null;
      final id = s.substring(i, i + 2);
      final lenStr = s.substring(i + 2, i + 4);
      final len = int.tryParse(lenStr);
      if (len == null || len < 0) return null;
      final start = i + 4;
      final end = start + len;
      if (end > n) return null;
      result[id] = s.substring(start, end);
      i = end;
      // Stop right after parsing the CRC field — anything after is invalid.
      if (id == '63') break;
    }
    return result;
  }

  /// EMVCo field 63 carries a CRC16-CCITT (poly 0x1021, init 0xFFFF) over
  /// all preceding bytes INCLUDING "6304". Verifies the CRC at the tail.
  static bool _verifyCrc(String s) {
    if (s.length < 8) return false;
    if (s[s.length - 8] != '6' || s[s.length - 7] != '3' ||
        s[s.length - 6] != '0' || s[s.length - 5] != '4') {
      return false;
    }
    final claimed = s.substring(s.length - 4).toUpperCase();
    final dataToCrc = s.substring(0, s.length - 4);
    final computed = _crc16Ccitt(dataToCrc).toRadixString(16).toUpperCase().padLeft(4, '0');
    return claimed == computed;
  }

  /// CRC-16/CCITT-FALSE, used by EMVCo.
  static int _crc16Ccitt(String input) {
    var crc = 0xFFFF;
    for (var i = 0; i < input.length; i++) {
      crc ^= input.codeUnitAt(i) << 8;
      for (var j = 0; j < 8; j++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return crc & 0xFFFF;
  }

  /// Computes the CRC over the EMVCo-style prefix (everything up to and
  /// INCLUDING "6304") and appends it. Used by test helpers / fixtures.
  static String appendCrc(String dataWith6304) {
    final crc = _crc16Ccitt(dataWith6304)
        .toRadixString(16)
        .toUpperCase()
        .padLeft(4, '0');
    return '$dataWith6304$crc';
  }

  static String _currencyFromNumeric(String numeric) {
    switch (numeric) {
      case '032':
        return 'ARS'; // Argentina peso
      case '170':
        return 'COP'; // Colombian peso
      case '356':
        return 'INR'; // Indian rupee
      case '484':
        return 'MXN'; // Mexican peso
      case '764':
        return 'THB'; // Thai baht
      case '840':
        return 'USD';
      case '978':
        return 'EUR';
      case '986':
        return 'BRL';
      default:
        return numeric.isEmpty ? '???' : numeric;
    }
  }

  /// Maps (country, currency) to the Bro billType registry id.
  static String _billTypeFor(String countryCode, String currencyNumeric) {
    switch (countryCode) {
      case 'BR':
        return 'pix';
      case 'MX':
        return 'mx_codi';
      case 'TH':
        return 'th_promptpay';
      case 'AR':
        return 'ar_transf3';
      case 'CO':
        return 'co_breb';
      case 'IN':
        return 'in_upi';
      default:
        // Unknown country — fall back to a stable identifier that won't
        // collide with the registry. Provider filter treats unknown ids
        // as legacy/show-by-default, so the order won't disappear.
        return 'emvco_${countryCode.toLowerCase()}';
    }
  }
}

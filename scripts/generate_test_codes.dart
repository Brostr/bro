// Test helper: generates valid EMVCo QR strings for MX/TH/AR/CO/IN/BR.
// Usage: dart run scripts/generate_test_codes.dart

int _crc16Ccitt(String input) {
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

String _tlv(String id, String value) {
  final len = value.length.toString().padLeft(2, '0');
  return '$id$len$value';
}

String _withCrc(String dataNoEndCrc) {
  // append "6304" then the CRC of everything-including-"6304"
  final withTag = '${dataNoEndCrc}6304';
  final crc = _crc16Ccitt(withTag).toRadixString(16).toUpperCase().padLeft(4, '0');
  return '$withTag$crc';
}

/// Builds a minimal valid EMVCo QR string.
/// [merchantAccount] is the field 26..51 sub-template content (e.g. for PIX
/// use id 26 with a nested PIX template). For test purposes we use a stub
/// account info template under id 26.
String buildEmvcoTestQr({
  required String country,        // ISO 3166-1 alpha-2
  required String currencyNum,    // ISO 4217 numeric (3 digits)
  required String amount,         // "10.50" — decimal as ASCII
  required String merchantName,   // <=25 chars
  required String merchantCity,   // <=15 chars
  String merchantAccount = '0014BR.GOV.BCB.PIX0114teste@bro.app', // dummy
}) {
  // Top-level fields per EMV QRCPS:
  // 00 = "01" (payload format indicator)
  // 01 = "11" or "12" (point-of-initiation method; 11=static, 12=dynamic)
  // 26..51 = merchant account info (we use 26)
  // 52 = "0000" (merchant category code - unspecified)
  // 53 = currency numeric
  // 54 = amount
  // 58 = country
  // 59 = merchant name
  // 60 = merchant city
  // 63 = CRC (auto-appended)
  final buf = StringBuffer();
  buf.write(_tlv('00', '01'));
  buf.write(_tlv('01', '12'));
  buf.write(_tlv('26', merchantAccount));
  buf.write(_tlv('52', '0000'));
  buf.write(_tlv('53', currencyNum));
  buf.write(_tlv('54', amount));
  buf.write(_tlv('58', country));
  buf.write(_tlv('59', merchantName));
  buf.write(_tlv('60', merchantCity));
  return _withCrc(buf.toString());
}

void main() {
  print('=== Bro test EMVCo QR codes (v588) ===\n');

  final samples = <Map<String, String>>[
    {
      'label': '🇧🇷 PIX (Brasil) — R\$ 12,50',
      'country': 'BR', 'curr': '986', 'amount': '12.50',
      'merchant': 'Bro Test', 'city': 'Sao Paulo',
    },
    {
      'label': '🇲🇽 CoDi (Mexico) — MXN 250.00',
      'country': 'MX', 'curr': '484', 'amount': '250.00',
      'merchant': 'Tienda Test', 'city': 'CDMX',
    },
    {
      'label': '🇹🇭 PromptPay (Tailandia) — THB 100.00',
      'country': 'TH', 'curr': '764', 'amount': '100.00',
      'merchant': 'Test Shop', 'city': 'Bangkok',
    },
    {
      'label': '🇦🇷 Transferencia 3.0 (Argentina) — ARS 5000.00',
      'country': 'AR', 'curr': '032', 'amount': '5000.00',
      'merchant': 'Comercio Test', 'city': 'Buenos Aires',
    },
    {
      'label': '🇨🇴 Bre-B (Colombia) — COP 25000',
      'country': 'CO', 'curr': '170', 'amount': '25000',
      'merchant': 'Tienda Test', 'city': 'Bogota',
    },
  ];

  for (final s in samples) {
    final qr = buildEmvcoTestQr(
      country: s['country']!,
      currencyNum: s['curr']!,
      amount: s['amount']!,
      merchantName: s['merchant']!,
      merchantCity: s['city']!,
    );
    print(s['label']);
    print(qr);
    print('');
  }
}

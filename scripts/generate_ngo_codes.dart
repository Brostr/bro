// Generates valid EMVCo PIX codes pointing to REAL NGO CNPJs (BR).
// These codes ARE payable — any Brazilian bank app will scan them and
// donate to the NGO. Useful for end-to-end testing in production-like flow.
//
// Usage: dart run scripts/generate_ngo_codes.dart

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
  final withTag = '${dataNoEndCrc}6304';
  final crc = _crc16Ccitt(withTag).toRadixString(16).toUpperCase().padLeft(4, '0');
  return '$withTag$crc';
}

/// Builds a static PIX (BR) using a CNPJ as the key.
String buildPixCnpj({
  required String cnpj14,         // CNPJ digits only, exactly 14 chars
  required String amount,         // "12.50" — empty means open value
  required String merchantName,   // <=25 chars (no accents)
  required String merchantCity,   // <=15 chars (no accents)
  String txid = '***',
}) {
  final pixTemplate = _tlv('00', 'BR.GOV.BCB.PIX') + _tlv('01', cnpj14);
  final addData = _tlv('05', txid);

  final buf = StringBuffer();
  buf.write(_tlv('00', '01'));
  buf.write(_tlv('01', '11')); // 11 = static
  buf.write(_tlv('26', pixTemplate));
  buf.write(_tlv('52', '0000'));
  buf.write(_tlv('53', '986'));
  if (amount.isNotEmpty) buf.write(_tlv('54', amount));
  buf.write(_tlv('58', 'BR'));
  buf.write(_tlv('59', merchantName));
  buf.write(_tlv('60', merchantCity));
  buf.write(_tlv('62', addData));
  return _withCrc(buf.toString());
}

void main() {
  print('=== PIX codes for REAL Brazilian NGOs ===');
  print('(payable from any BR bank app — and parseable by Bro)\n');

  final ngos = <Map<String, String>>[
    {
      'name': 'GRAACC',
      'desc': 'Hospital infantil de cancer (SP)',
      'cnpj': '67185694000150',
      'merchant': 'GRAACC',
      'city': 'Sao Paulo',
    },
    {
      'name': 'Doutores da Alegria',
      'desc': 'Palhacos em hospitais infantis',
      'cnpj': '00491904000167',
      'merchant': 'Doutores da Alegria',
      'city': 'Sao Paulo',
    },
    {
      'name': 'Medicos Sem Fronteiras Brasil',
      'desc': 'Ajuda humanitaria global',
      'cnpj': '08273224000166',
      'merchant': 'MSF Brasil',
      'city': 'Rio de Janeiro',
    },
  ];

  for (final n in ngos) {
    final cnpj = n['cnpj']!;
    // Sem valor (doador escolhe)
    final open = buildPixCnpj(
      cnpj14: cnpj,
      amount: '',
      merchantName: n['merchant']!,
      merchantCity: n['city']!,
    );
    // R$ 5,00 fixo (bom pra testar conversao em sats)
    final fixed = buildPixCnpj(
      cnpj14: cnpj,
      amount: '5.00',
      merchantName: n['merchant']!,
      merchantCity: n['city']!,
    );
    print('## ${n['name']} — ${n['desc']}');
    print('   CNPJ: $cnpj');
    print('   [doador escolhe valor]');
    print('   $open');
    print('   [valor fixo R\$ 5,00]');
    print('   $fixed');
    print('');
  }
}

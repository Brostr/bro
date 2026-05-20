// Generates a valid EMVCo Transferencias 3.0 (Argentina) QR string.
//
// Notes:
// - Real Transf 3.0 codes use template 26/29 with AID "AR.COM.COELSA.QR"
//   and a CVU/CBU/alias as the merchant key. Currency = ARS (032).
// - This script produces a STRUCTURALLY VALID EMVCo string with a real
//   CRC16-CCITT-FALSE checksum. Bro will parse it correctly (country=AR,
//   currency=ARS, billType=ar_transf3) and create an order.
// - To make it ACTUALLY payable in an Argentine bank app, replace `alias`
//   below with a real ONG alias / CVU / CBU.
//
// Usage: dart run scripts/generate_ar_code.dart [amount_ARS]

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

String buildTransf3({
  required String alias,         // ONG alias (ex: 'cruzroja.arg' or CVU 22 digits)
  required String amount,        // "5000.00" - empty = aberto
  required String merchantName,  // <=25 chars no accents
  required String merchantCity,  // <=15 chars no accents
}) {
  // Template 26: AID + chave (Coelsa)
  final template = _tlv('00', 'AR.COM.COELSA.QR') + _tlv('01', alias);

  final buf = StringBuffer();
  buf.write(_tlv('00', '01'));       // Payload format
  buf.write(_tlv('01', '11'));       // Static QR
  buf.write(_tlv('26', template));
  buf.write(_tlv('52', '0000'));     // MCC
  buf.write(_tlv('53', '032'));      // Currency ARS
  if (amount.isNotEmpty) buf.write(_tlv('54', amount));
  buf.write(_tlv('58', 'AR'));
  buf.write(_tlv('59', merchantName));
  buf.write(_tlv('60', merchantCity));
  return _withCrc(buf.toString());
}

void main(List<String> args) {
  final amount = args.isNotEmpty ? args[0] : '5000.00';

  print('=== Transf 3.0 (Argentina) test codes ===\n');

  // 1. Test code — alias fake, parseável mas NÃO pagável
  final test = buildTransf3(
    alias: 'bro.test.ar',
    amount: amount,
    merchantName: 'Bro Test AR',
    merchantCity: 'Buenos Aires',
  );
  print('## Codigo de teste (alias fake — so parser)');
  print('   ARS \$amount → $amount');
  print('   $test\n');

  // 2. Cruz Roja Argentina — alias publico (atualizar se mudar)
  //    Verifique em: https://www.cruzroja.org.ar/donar/
  //    Sem chave publica documentada na hora — substitua manualmente.
  final cruzRoja = buildTransf3(
    alias: 'cruzroja.arg',
    amount: amount,
    merchantName: 'Cruz Roja Argentina',
    merchantCity: 'Buenos Aires',
  );
  print('## Cruz Roja Argentina (alias EXEMPLO — verifique antes de usar)');
  print('   $cruzRoja\n');

  // 3. UNICEF Argentina
  final unicef = buildTransf3(
    alias: 'unicef.argentina',
    amount: amount,
    merchantName: 'UNICEF Argentina',
    merchantCity: 'Buenos Aires',
  );
  print('## UNICEF Argentina (alias EXEMPLO — verifique antes de usar)');
  print('   $unicef\n');

  print('Pra gerar com alias real: edite o script ou passe o valor: '
      'dart run scripts/generate_ar_code.dart 1000.00');
}

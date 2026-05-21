// Quick simulation: parse each generated test code with EmvcoQrParser.
// Run: dart run scripts/test_emvco_parser.dart

import '../lib/services/emvco_qr_parser.dart';

void main() {
  final codes = {
    'BR':
        '00020101021226350014BR.GOV.BCB.PIX0114teste@bro.app520400005303986540512.505802BR5908Bro Test6009Sao Paulo6304E751',
    'MX':
        '00020101021226350014BR.GOV.BCB.PIX0114teste@bro.app5204000053034845406250.005802MX5911Tienda Test6004CDMX63041A4F',
    'TH':
        '00020101021226350014BR.GOV.BCB.PIX0114teste@bro.app5204000053037645406100.005802TH5909Test Shop6007Bangkok6304A305',
    'AR':
        '00020101021226350014BR.GOV.BCB.PIX0114teste@bro.app52040000530303254075000.005802AR5913Comercio Test6012Buenos Aires630498F9',
    'CO':
        '00020101021226350014BR.GOV.BCB.PIX0114teste@bro.app5204000053031705405250005802CO5911Tienda Test6006Bogota63049A07',
  };

  for (final entry in codes.entries) {
    final r = EmvcoQrParser.parse(entry.value);
    print('${entry.key}: ${r ?? "PARSE FAILED"}');
  }

  // Negative test: tampered CRC should fail.
  final tampered =
      '00020101021226350014BR.GOV.BCB.PIX0114teste@bro.app520400005303986540512.505802BR5908Bro Test6009Sao Paulo63040000';
  print('BR (tampered CRC) → ${EmvcoQrParser.parse(tampered) == null ? 'rejected ✓' : 'INCORRECTLY ACCEPTED'}');
}

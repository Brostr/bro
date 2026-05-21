// Simulação: gera QRs EMVCo (PIX/CoDi/PromptPay/Transf3/Bre-B/UPI),
// roda o parser e valida country/currency/billType/amount.
//
// Cobre:
//   1. PIX (BR/BRL/986)         → billType=pix
//   2. CoDi (MX/MXN/484)        → billType=mx_codi
//   3. PromptPay (TH/THB/764)   → billType=th_promptpay
//   4. Transf3 (AR/ARS/032)     → billType=ar_transf3
//   5. Bre-B (CO/COP/170)       → billType=co_breb
//   6. UPI (IN/INR/356)         → billType=in_upi
//   7. FRANKEN-QR (template BR.GOV.BCB.PIX mas country CO/currency COP):
//      o parser DEVE confiar nos campos 53/58, não no template — alvo do bug.

import 'package:flutter_test/flutter_test.dart';
import 'package:bro_app/services/emvco_qr_parser.dart';

/// Monta um QR EMVCo mínimo: PayloadFormatIndicator + (opcional) template 26,
/// MCC=0000, currency, amount, country, merchant, city, e CRC.
String buildQr({
  required String countryCode,
  required String currencyNumeric, // ISO-4217 (3 dígitos)
  required String amount,          // "25.00" etc.
  required String merchant,
  required String city,
  String? template26, // ex.: "0014BR.GOV.BCB.PIX0114teste@bro.app"
}) {
  String tlv(String id, String v) =>
      '$id${v.length.toString().padLeft(2, '0')}$v';

  final pfi = tlv('00', '01');
  final tpl = template26 != null ? tlv('26', template26) : '';
  final mcc = tlv('52', '0000');
  final cur = tlv('53', currencyNumeric);
  final amt = amount.isNotEmpty ? tlv('54', amount) : '';
  final cc = tlv('58', countryCode);
  final m = tlv('59', merchant);
  final c = tlv('60', city);
  // Field 63 is CRC: build everything + "6304", then append CRC.
  final prefix = '$pfi$tpl$mcc$cur$amt$cc$m$c' '6304';
  return EmvcoQrParser.appendCrc(prefix);
}

void main() {
  group('EMVCo simulation — todas as bandeiras', () {
    test('PIX (BR/BRL)', () {
      final qr = buildQr(
        countryCode: 'BR',
        currencyNumeric: '986',
        amount: '50.00',
        merchant: 'Loja Teste',
        city: 'Sao Paulo',
        template26: '0014BR.GOV.BCB.PIX0114teste@bro.app',
      );
      final r = EmvcoQrParser.parse(qr)!;
      expect(r.countryCode, 'BR');
      expect(r.currencyCode, 'BRL');
      expect(r.billType, 'pix');
      expect(r.amount, 50.0);
    });

    test('CoDi (MX/MXN)', () {
      final qr = buildQr(
        countryCode: 'MX',
        currencyNumeric: '484',
        amount: '120.50',
        merchant: 'Tienda Test',
        city: 'CDMX',
      );
      final r = EmvcoQrParser.parse(qr)!;
      expect(r.countryCode, 'MX');
      expect(r.currencyCode, 'MXN');
      expect(r.billType, 'mx_codi');
      expect(r.amount, 120.50);
    });

    test('PromptPay (TH/THB)', () {
      final qr = buildQr(
        countryCode: 'TH',
        currencyNumeric: '764',
        amount: '200',
        merchant: 'Bangkok Shop',
        city: 'Bangkok',
      );
      final r = EmvcoQrParser.parse(qr)!;
      expect(r.countryCode, 'TH');
      expect(r.currencyCode, 'THB');
      expect(r.billType, 'th_promptpay');
    });

    test('Transferencias 3.0 (AR/ARS)', () {
      final qr = buildQr(
        countryCode: 'AR',
        currencyNumeric: '032',
        amount: '3500',
        merchant: 'Tienda BA',
        city: 'Buenos Aires',
      );
      final r = EmvcoQrParser.parse(qr)!;
      expect(r.countryCode, 'AR');
      expect(r.currencyCode, 'ARS');
      expect(r.billType, 'ar_transf3');
    });

    test('Bre-B (CO/COP)', () {
      final qr = buildQr(
        countryCode: 'CO',
        currencyNumeric: '170',
        amount: '25000',
        merchant: 'Tienda CO',
        city: 'Bogota',
      );
      final r = EmvcoQrParser.parse(qr)!;
      expect(r.countryCode, 'CO');
      expect(r.currencyCode, 'COP');
      expect(r.billType, 'co_breb');
    });

    test('UPI (IN/INR)', () {
      final qr = buildQr(
        countryCode: 'IN',
        currencyNumeric: '356',
        amount: '500',
        merchant: 'Mumbai Store',
        city: 'Mumbai',
      );
      final r = EmvcoQrParser.parse(qr)!;
      expect(r.countryCode, 'IN');
      expect(r.currencyCode, 'INR');
      expect(r.billType, 'in_upi');
    });

    test('FRANKEN-QR: template PIX mas country CO/currency COP', () {
      // Caso reportado pelo usuário: o app classificava como PIX/BRL
      // porque a string contém "BR.GOV.BCB.PIX". O parser correto deve
      // priorizar os campos 53 e 58 sobre o conteúdo do template 26.
      final qr = buildQr(
        countryCode: 'CO',
        currencyNumeric: '170',
        amount: '25.00',
        merchant: 'Tienda Test',
        city: 'Bogota',
        template26: '0014BR.GOV.BCB.PIX0114teste@bro.app',
      );
      final r = EmvcoQrParser.parse(qr)!;
      expect(r.countryCode, 'CO', reason: 'country deve vir de 58, não do template');
      expect(r.currencyCode, 'COP', reason: 'currency deve vir de 53, não do template');
      expect(r.billType, 'co_breb');
      expect(r.amount, 25.0);
    });

    test('CRC inválido → null', () {
      // Quebra o CRC do último QR válido.
      final qr = buildQr(
        countryCode: 'CO',
        currencyNumeric: '170',
        amount: '25.00',
        merchant: 'X',
        city: 'X',
      );
      final tampered = '${qr.substring(0, qr.length - 4)}0000';
      expect(EmvcoQrParser.parse(tampered), isNull);
    });
  });
}

import 'package:bro_app/services/platform_fee_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// R4 — auditoria da tela Admin.
///
/// Cobre as duas correções de dados que mudam números mostrados à mediadora:
/// 1. `recordFee` é idempotente por orderId (antes a mesma ordem podia gerar
///    2-3 registros e inflar "Total Histórico"/"Taxas Pendentes").
/// 2. `getHistoricalTotals`/`getPendingFees` continuam consistentes depois da
///    deduplicação.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PlatformFeeService.clearAllRecords();
  });

  test('recordFee ignora duplicata da mesma ordem', () async {
    await PlatformFeeService.recordFee(
      orderId: 'order-abc',
      transactionBrl: 100.0,
      transactionSats: 10000,
      providerPubkey: 'provider-1',
      clientPubkey: 'client-1',
    );
    // Segundo call site (payment_screen, escrow_split, order_status...) para a
    // MESMA ordem — antes virava um segundo registro e dobrava o total.
    await PlatformFeeService.recordFee(
      orderId: 'order-abc',
      transactionBrl: 100.0,
      transactionSats: 10000,
      providerPubkey: 'provider-1',
      clientPubkey: 'client-1',
    );

    final records = await PlatformFeeService.getAllFeeRecords();
    expect(records.length, 1);

    final totals = await PlatformFeeService.getHistoricalTotals();
    expect(totals['totalTransactions'], 1);
    // 2% de 10000 sats = 200 sats (não 400).
    expect(totals['totalSats'], 200);
  });

  test('recordFee mantém ordens distintas', () async {
    await PlatformFeeService.recordFee(
      orderId: 'order-1',
      transactionBrl: 50.0,
      transactionSats: 5000,
      providerPubkey: 'p',
      clientPubkey: 'c',
    );
    await PlatformFeeService.recordFee(
      orderId: 'order-2',
      transactionBrl: 50.0,
      transactionSats: 5000,
      providerPubkey: 'p',
      clientPubkey: 'c',
    );

    final records = await PlatformFeeService.getAllFeeRecords();
    expect(records.length, 2);

    final totals = await PlatformFeeService.getHistoricalTotals();
    expect(totals['totalTransactions'], 2);
    expect(totals['totalSats'], 200); // 100 + 100
  });

  test('taxa pendente não duplica ao registrar duas vezes', () async {
    await PlatformFeeService.recordFee(
      orderId: 'order-pending',
      transactionBrl: 200.0,
      transactionSats: 20000,
      providerPubkey: 'p',
      clientPubkey: 'c',
    );
    await PlatformFeeService.recordFee(
      orderId: 'order-pending',
      transactionBrl: 200.0,
      transactionSats: 20000,
      providerPubkey: 'p',
      clientPubkey: 'c',
    );

    final pending = await PlatformFeeService.getPendingFees();
    expect(pending.length, 1);
    expect(pending.first['feeSats'], 400); // 2% de 20000
  });
}

import 'package:bro_app/services/brix_relay_service.dart';
import 'package:bro_app/services/platform_fee_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PlatformFeeService.clearPaidOrders();
    BrixRelayService.chargeOutgoingFeeOverride = ({
      required orderId,
      required totalSats,
      required feePercent,
      required onPaid,
    }) async {
      await onPaid('platform-fee-hash');
      return true;
    };
  });

  tearDown(() {
    BrixRelayService.chargeOutgoingFeeOverride = null;
  });

  test('receiving is free; outgoing fee is 0.5% with one-sat minimum', () {
    expect(BrixRelayService.calculateBrixFee(0), 0);
    expect(BrixRelayService.calculateBrixFee(1), 1);
    expect(BrixRelayService.calculateBrixFee(14), 1);
    expect(BrixRelayService.calculateBrixFee(200), 1);
    expect(BrixRelayService.calculateBrixFee(1000), 5);
  });

  test('settled outgoing fee is persisted by exact payment hash', () async {
    await BrixRelayService.recordSettledOutgoingFee(
      paymentHash: 'outgoing-hash',
      amountSats: 200,
      feeSats: 1,
    );

    final fees = await BrixRelayService.getSettledOutgoingFees();
    expect(fees['outgoing-hash'], {
      'amountSats': 200,
      'feeSats': 1,
      'feePaymentHash': 'platform-fee-hash',
    });
  });

  test('repeated settlement updates the same hash without duplicate entries', () async {
    await BrixRelayService.recordSettledOutgoingFee(
      paymentHash: 'same-hash',
      amountSats: 200,
      feeSats: 1,
    );
    await BrixRelayService.recordSettledOutgoingFee(
      paymentHash: 'same-hash',
      amountSats: 200,
      feeSats: 1,
    );

    final fees = await BrixRelayService.getSettledOutgoingFees();
    expect(fees, hasLength(1));
    expect(fees['same-hash']?['feeSats'], 1);
    expect(fees['same-hash']?['feePaymentHash'], 'platform-fee-hash');
  });

  test('pending fee hash is preserved for restart reconciliation', () async {
    BrixRelayService.chargeOutgoingFeeOverride = ({
      required orderId,
      required totalSats,
      required feePercent,
      required onPaid,
    }) async {
      await onPaid('pending-fee-hash');
      return false;
    };

    await BrixRelayService.recordSettledOutgoingFee(
      paymentHash: 'restart-hash',
      amountSats: 200,
      feeSats: 1,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('brix_pending_outgoing_fees'), contains('pending-fee-hash'));
    expect(await BrixRelayService.getSettledOutgoingFees(), isEmpty);
  });

  test('fee charge failure does not mark outgoing fee as settled', () async {
    await PlatformFeeService.clearPaidOrders();
    BrixRelayService.chargeOutgoingFeeOverride = ({
      required orderId,
      required totalSats,
      required feePercent,
      required onPaid,
    }) async => false;

    await BrixRelayService.recordSettledOutgoingFee(
      paymentHash: 'unconfirmed-hash',
      amountSats: 200,
      feeSats: 1,
    );

    expect(await BrixRelayService.getSettledOutgoingFees(), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('brix_pending_outgoing_fees'), contains('unconfirmed-hash'));
  });
}

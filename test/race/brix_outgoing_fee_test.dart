import 'package:bro_app/screens/wallet_screen.dart';
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

  test('idempotency key is a canonical UUID accepted by the SDK', () {
    final key = BrixRelayService.brixIdempotencyKey('abc123hash');
    expect(
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
          .hasMatch(key),
      isTrue,
      reason: 'SDK rejects non-UUID TransferId: $key',
    );
    expect(BrixRelayService.brixIdempotencyKey('abc123hash'), key);
    expect(BrixRelayService.brixIdempotencyKey('other'), isNot(key));
  });

  test('legacy non-UUID queue keys are normalized before sending', () {
    final legacy = BrixRelayService.normalizeIdempotencyKey(
        'brix-abc123hash', ['abc123hash']);
    expect(
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
          .hasMatch(legacy),
      isTrue,
    );
    expect(legacy, BrixRelayService.brixIdempotencyKey('abc123hash'));

    final valid = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';
    expect(BrixRelayService.normalizeIdempotencyKey(valid, const []), valid);
  });

  test('BRIX fee is always charged, even when it equals the network cost',
      () async {
    SharedPreferences.setMockInitialValues({});
    var charges = 0;
    BrixRelayService.chargeOutgoingFeeOverride = ({
      required orderId,
      required totalSats,
      required feePercent,
      required onPaid,
    }) async {
      charges++;
      await onPaid('fee-hash');
      return true;
    };

    await BrixRelayService.recordSettledOutgoingFee(
      paymentHash: 'tiny-fee-hash',
      amountSats: 214,
      feeSats: 1,
      feeNetworkReserveSats: 1,
    );

    expect(charges, 1, reason: 'BRIX is a paid service — fee must be charged');
    final fees = await BrixRelayService.getSettledOutgoingFees();
    expect(fees['tiny-fee-hash']?['feeSats'], 1);
    BrixRelayService.chargeOutgoingFeeOverride = null;
  });

  test('manual BRIX amount is the total debit including both fees', () {
    expect(isBrixSendDestination('carol@brix.brostr.app'), isTrue);
    expect(isBrixSendDestination('carol'), isTrue);
    expect(isBrixSendDestination('carol@coinos.io'), isFalse);
    expect(maxBrixSendAmount(1000), 1000);
    expect(maxBrixSendAmount(1), 1);
    expect(maxBrixSendAmount(0), 0);

    expect(brixManualAmounts(totalSats: 300, networkFeeSats: 2), {
      'totalSats': 300,
      'brixFeeSats': 2,
      'networkFeeSats': 2,
      'receiverSats': 296,
    });
    expect(brixManualAmounts(totalSats: 200, networkFeeSats: 1), {
      'totalSats': 200,
      'brixFeeSats': 1,
      'networkFeeSats': 1,
      'receiverSats': 198,
    });
  });

  test('only a completed payment can trigger the outgoing fee', () {
    expect(
        isCompletedWalletPayment({
          'success': true,
          'payment': {'status': 'PaymentStatus.completed'},
        }),
        isTrue);
    expect(
        isCompletedWalletPayment({
          'success': true,
          'payment': {'status': 'PaymentStatus.pending'},
        }),
        isFalse);
    expect(isCompletedWalletPayment({'success': true}), isFalse);
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

  test('repeated settlement updates the same hash without duplicate entries',
      () async {
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

  test('concurrent settlement calls charge at most once', () async {
    var charges = 0;
    BrixRelayService.chargeOutgoingFeeOverride = ({
      required orderId,
      required totalSats,
      required feePercent,
      required onPaid,
    }) async {
      charges++;
      await Future.delayed(const Duration(milliseconds: 20));
      await onPaid('platform-fee-hash');
      return true;
    };

    await Future.wait([
      BrixRelayService.recordSettledOutgoingFee(
        paymentHash: 'concurrent-hash',
        amountSats: 200,
        feeSats: 1,
      ),
      BrixRelayService.recordSettledOutgoingFee(
        paymentHash: 'concurrent-hash',
        amountSats: 200,
        feeSats: 1,
      ),
    ]);

    expect(charges, 1);
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
    expect(prefs.getString('brix_pending_outgoing_fees'),
        contains('pending-fee-hash'));
    expect(await BrixRelayService.getSettledOutgoingFees(), isEmpty);
  });

  test('fee charge failure does not mark outgoing fee as settled', () async {
    await PlatformFeeService.clearPaidOrders();
    BrixRelayService.chargeOutgoingFeeOverride = ({
      required orderId,
      required totalSats,
      required feePercent,
      required onPaid,
    }) async =>
        false;

    await BrixRelayService.recordSettledOutgoingFee(
      paymentHash: 'unconfirmed-hash',
      amountSats: 200,
      feeSats: 1,
    );

    expect(await BrixRelayService.getSettledOutgoingFees(), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('brix_pending_outgoing_fees'),
        contains('unconfirmed-hash'));
  });
}

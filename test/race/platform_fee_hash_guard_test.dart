import 'dart:async';

import 'package:bro_app/services/platform_fee_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PlatformFeeService.clearPaidOrders();
  });

  test('unconfirmed saved fee hash is fail-closed', () async {
    var paymentCalls = 0;
    PlatformFeeService.setPaymentCallback((invoice) async {
      paymentCalls++;
      return {'success': true};
    }, 'test');

    final paid = await PlatformFeeService.sendPlatformFee(
      orderId: 'unconfirmed-hash-order',
      totalSats: 1000,
      knownFeeHash: 'previous-fee-hash',
      hashConfirmedOverride: (_) async => false,
    );

    expect(paid, isFalse);
    expect(paymentCalls, 0);
    expect(PlatformFeeService.isFeePaid('unconfirmed-hash-order'), isFalse);
  });

  test('concurrent hash checks cannot acquire the payment lock twice', () async {
    final firstCheck = Completer<void>();
    final releaseCheck = Completer<void>();
    var checks = 0;
    var paymentCalls = 0;
    PlatformFeeService.setPaymentCallback((invoice) async {
      paymentCalls++;
      return {'success': true};
    }, 'test');

    Future<bool> confirm(String hash) async {
      checks++;
      if (checks == 1) {
        firstCheck.complete();
        await releaseCheck.future;
      }
      return true;
    }

    final first = PlatformFeeService.sendPlatformFee(
      orderId: 'concurrent-hash-order',
      totalSats: 1000,
      knownFeeHash: 'previous-fee-hash',
      hashConfirmedOverride: confirm,
    );
    await firstCheck.future;
    final second = PlatformFeeService.sendPlatformFee(
      orderId: 'concurrent-hash-order',
      totalSats: 1000,
      knownFeeHash: 'previous-fee-hash',
      hashConfirmedOverride: confirm,
    );
    releaseCheck.complete();

    expect(await Future.wait([first, second]), [true, true]);
    expect(paymentCalls, 0);
    expect(PlatformFeeService.isFeePaid('concurrent-hash-order'), isTrue);
  });
}

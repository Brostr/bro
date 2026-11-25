import 'dart:async';

import 'package:bro_app/screens/wallet_screen.dart';
import 'package:bro_app/services/brix_relay_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _payment({int fee = 0, int gross = 59}) => {
      'paymentHash': 'hash-59',
      'amountSats': 59,
      'grossAmountSats': gross,
      'feeSats': fee,
      'description': 'BRIX Payment',
      'createdAt': '2026-11-24T12:00:00.000Z',
      'type': 'received',
      'direction': 'incoming',
      'status': 'Complete',
      'isBrix': true,
    };

void main() {
  group('BRIX fee reconciliation by paymentHash', () {
    test('Spark first, claim second enriches one stored payment', () {
      final payments = <dynamic>[];
      BrixRelayService.mergeBrixPayment(payments, _payment());
      BrixRelayService.mergeBrixPayment(payments, _payment(fee: 1, gross: 60));

      expect(payments, hasLength(1));
      expect(payments.single['amountSats'], 59);
      expect(payments.single['grossAmountSats'], 60);
      expect(payments.single['feeSats'], 1);
      expect(payments.single['createdAt'], '2026-11-24T12:00:00.000Z');
    });

    test('late Spark event cannot erase authenticated fee metadata', () {
      final payments = <dynamic>[_payment(fee: 1, gross: 60)];
      final changed = BrixRelayService.mergeBrixPayment(payments, _payment());

      expect(changed, isFalse);
      expect(payments.single['feeSats'], 1);
      expect(payments.single['grossAmountSats'], 60);
    });

    test('conflicting fee metadata is not overwritten', () {
      final payments = <dynamic>[_payment(fee: 1, gross: 60)];
      final changed = BrixRelayService.mergeBrixPayment(
          payments, _payment(fee: 2, gross: 61));

      expect(changed, isFalse);
      expect(payments.single['feeSats'], 1);
      expect(payments.single['grossAmountSats'], 60);
    });

    test('wallet enriches existing SDK payment without replacing SDK fields',
        () {
      final sdkPayment = {
        ..._payment(),
        'id': 'spark-id',
        'timestamp': 1764000000,
        'fees': 0,
      };
      final merged =
          mergeBrixWalletPayment(sdkPayment, _payment(fee: 1, gross: 60));

      expect(merged['id'], 'spark-id');
      expect(merged['timestamp'], 1764000000);
      expect(merged['amountSats'], 59);
      expect(merged['grossAmountSats'], 60);
      expect(merged['feeSats'], 1);
      expect(merged['isBrix'], isTrue);
    });

    test('platform filter preserves legacy BRIX fee but hides order fee', () {
      expect(
        shouldHideFeePayment(
          paymentHash: 'legacy-brix-fee',
          platformFeeHashes: {'legacy-brix-fee', 'order-fee'},
          brixFeeHashes: {'legacy-brix-fee'},
        ),
        isFalse,
      );
      expect(
        shouldHideFeePayment(
          paymentHash: 'order-fee',
          platformFeeHashes: {'legacy-brix-fee', 'order-fee'},
          brixFeeHashes: {'legacy-brix-fee'},
        ),
        isTrue,
      );
    });

    test('concurrent storage operations cannot overwrite each other', () async {
      final stored = <dynamic>[];
      final firstRead = Completer<void>();
      final releaseFirstRead = Completer<void>();
      var reads = 0;

      Future<void> persist(Map<String, dynamic> payment) {
        return BrixRelayService.serializeBrixStorage(() async {
          final snapshot = stored
              .map((p) => Map<String, dynamic>.from(p as Map))
              .toList();
          reads++;
          if (reads == 1) {
            firstRead.complete();
            await releaseFirstRead.future;
          }
          BrixRelayService.mergeBrixPayment(snapshot, payment);
          stored
            ..clear()
            ..addAll(snapshot);
        });
      }

      final spark = persist(_payment());
      await firstRead.future;
      final claim = persist(_payment(fee: 1, gross: 60));
      releaseFirstRead.complete();
      await Future.wait([spark, claim]);

      expect(stored, hasLength(1));
      expect(stored.single['feeSats'], 1);
      expect(stored.single['grossAmountSats'], 60);
    });
  });
}

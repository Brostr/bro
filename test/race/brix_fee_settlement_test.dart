import 'dart:async';
import 'dart:convert';

import 'package:bro_app/services/brix_relay_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const paymentHash = 'incoming-payment-hash';
  const amountSats = 281000;

  Map<String, dynamic> settledIncomingPayment() => {
        'paid': true,
        'paymentHash': paymentHash,
        'direction': 'receive',
        'amountSats': amountSats.toString(),
      };

  test('accepts only the exact settled incoming payment', () {
    expect(
      BrixRelayService.isSettledIncomingPayment(
        settledIncomingPayment(),
        paymentHash: paymentHash,
        amountSats: amountSats,
      ),
      isTrue,
    );
  });

  test('rejects an invoice that was created but not paid', () {
    final status = settledIncomingPayment()..['paid'] = false;

    expect(
      BrixRelayService.isSettledIncomingPayment(
        status,
        paymentHash: paymentHash,
        amountSats: amountSats,
      ),
      isFalse,
    );
  });

  test('rejects a settled outgoing payment with the same hash', () {
    final status = settledIncomingPayment()..['direction'] = 'send';

    expect(
      BrixRelayService.isSettledIncomingPayment(
        status,
        paymentHash: paymentHash,
        amountSats: amountSats,
      ),
      isFalse,
    );
  });

  test('rejects a different amount or payment hash', () {
    final wrongAmount = settledIncomingPayment()..['amountSats'] = '280000';
    final wrongHash = settledIncomingPayment()..['paymentHash'] = 'other-hash';

    for (final status in [wrongAmount, wrongHash]) {
      expect(
        BrixRelayService.isSettledIncomingPayment(
          status,
          paymentHash: paymentHash,
          amountSats: amountSats,
        ),
        isFalse,
      );
    }
  });

  test('rejects legacy status without direction or hash binding', () {
    expect(
      BrixRelayService.isSettledIncomingPayment(
        {'paid': true, 'amountSats': amountSats.toString()},
        paymentHash: paymentHash,
        amountSats: amountSats,
      ),
      isFalse,
    );
  });

  group('outgoing fee settlement', () {
    Map<String, dynamic> payResult(String status) => {
          'success': true,
          'payment': {
            'status': status,
            'paymentHash': 'fee-hash',
            'amount': '1405',
          },
        };

    test('accepts only a completed outgoing payment with the exact hash', () {
      expect(
        BrixRelayService.isSettledOutgoingFee(
          payResult('PaymentStatus.completed'),
          paymentHash: 'fee-hash',
          feeSats: 1405,
        ),
        isTrue,
      );
      expect(
        BrixRelayService.isSettledOutgoingFee(
          payResult('PaymentStatus.completed'),
          paymentHash: 'other-hash',
          feeSats: 1405,
        ),
        isFalse,
      );
    });

    test('pending success is not settled and is not a definitive failure', () {
      final result = payResult('PaymentStatus.pending');
      expect(
        BrixRelayService.isSettledOutgoingFee(
          result,
          paymentHash: 'fee-hash',
          feeSats: 1405,
        ),
        isFalse,
      );
      expect(BrixRelayService.isDefinitivelyFailedOutgoingFee(result), isFalse);
    });

    test('timeout remains pending while explicit failure is definitive', () {
      expect(
        BrixRelayService.isDefinitivelyFailedOutgoingFee({
          'success': false,
          'mayStillSucceed': true,
        }),
        isFalse,
      );
      expect(
        BrixRelayService.isDefinitivelyFailedOutgoingFee(
          payResult('PaymentStatus.failed'),
        ),
        isTrue,
      );
    });

    test('reconciliation requires exact outgoing hash, direction and amount', () {
      final status = {
        'paid': true,
        'paymentHash': 'fee-hash',
        'direction': 'send',
        'amountSats': '1405',
      };
      expect(
        BrixRelayService.isSettledOutgoingFeeStatus(
          status,
          paymentHash: 'fee-hash',
          feeSats: 1405,
        ),
        isTrue,
      );
      expect(
        BrixRelayService.isSettledOutgoingFeeStatus(
          {...status, 'direction': 'receive'},
          paymentHash: 'fee-hash',
          feeSats: 1405,
        ),
        isFalse,
      );
      expect(
        BrixRelayService.isSettledOutgoingFeeStatus(
          {...status, 'amountSats': '1404'},
          paymentHash: 'fee-hash',
          feeSats: 1405,
        ),
        isFalse,
      );
    });
  });

  group('persistent fee lifecycle', () {
    const requestId = 'fee-request';
    const feeInvoice = 'fee-bolt11';
    const feeHash = 'fee-hash';

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      BrixRelayService().resetFeeStateForTest();
    });

    Future<List<Map<String, dynamic>>> pendingFees() async {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('brix_pending_fee_payments') ?? '[]';
      return (jsonDecode(raw) as List)
          .map((fee) => Map<String, dynamic>.from(fee as Map))
          .toList();
    }

    Future<void> queueFee(BrixRelayService service) {
      return service.queueBrixFeeForTest(
        requestId: requestId,
        paymentHash: paymentHash,
        bolt11: 'incoming-bolt11',
        amountSats: amountSats,
        feeSats: 1405,
      );
    }

    Future<void> sendFee(
      BrixRelayService service,
      Future<Map<String, dynamic>?> Function(
        String bolt11,
        String idempotencyKey,
      ) payInvoice,
    ) {
      return service.sendBrixFeeForTest(
        {
          'requestId': requestId,
          'feeSats': 1405,
          'idempotencyKey': '11111111-1111-4111-8111-111111111111',
        },
        getInvoice: () async => {'success': true, 'invoice': feeInvoice},
        decodeInvoice: (_) async => {
          'success': true,
          'invoice': {'paymentHash': feeHash, 'amountSats': '1405'},
        },
        payInvoice: payInvoice,
      );
    }

    test('missing incoming hash is queued and recovered without losing the fee', () async {
      final service = BrixRelayService();
      await service.queueBrixFeeForTest(
        requestId: requestId,
        paymentHash: null,
        bolt11: 'incoming-bolt11',
        amountSats: amountSats,
        feeSats: 1405,
      );

      var fees = await pendingFees();
      expect(fees.single['state'], BrixFeeState.awaitingPaymentHash.name);
      expect(fees.single['bolt11'], 'incoming-bolt11');

      await service.updateBrixFeeForTest(requestId, (fee) {
        fee['paymentHash'] = paymentHash;
        fee['state'] = BrixFeeState.awaitingReceipt.name;
      });
      fees = await pendingFees();
      expect(fees.single['paymentHash'], paymentHash);
      expect(fees.single['state'], BrixFeeState.awaitingReceipt.name);
    });

    test('failed pre-payment persistence prevents payInvoice', () async {
      final service = BrixRelayService();
      await queueFee(service);
      final prefs = await SharedPreferences.getInstance();
      service.resetFeeStateForTest(
        preferences: () async => FailingWritePreferences(prefs),
      );
      var payCalls = 0;

      await sendFee(service, (_, __) async {
        payCalls++;
        return null;
      });

      expect(payCalls, 0);
      expect((await pendingFees()).single['state'], BrixFeeState.awaitingReceipt.name);
    });

    test('throwing pre-payment persistence prevents payInvoice', () async {
      final service = BrixRelayService();
      await queueFee(service);
      final prefs = await SharedPreferences.getInstance();
      service.resetFeeStateForTest(
        preferences: () async => FailingWritePreferences(prefs, throwOnWrite: true),
      );
      var payCalls = 0;

      await sendFee(service, (_, __) async {
        payCalls++;
        return null;
      });

      expect(payCalls, 0);
      expect((await pendingFees()).single['state'], BrixFeeState.awaitingReceipt.name);
    });

    test('corrupt queue fails closed and is not overwritten', () async {
      final service = BrixRelayService();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('brix_pending_fee_payments', '{invalid-json');

      await expectLater(
        service.queueBrixFeeForTest(
          requestId: requestId,
          paymentHash: paymentHash,
          bolt11: 'incoming-bolt11',
          amountSats: amountSats,
          feeSats: 1405,
        ),
        throwsStateError,
      );
      expect(prefs.getString('brix_pending_fee_payments'), '{invalid-json');
    });

    test('restart resumes sending with the persisted idempotency key', () async {
      final service = BrixRelayService();
      const idempotencyKey = '11111111-1111-4111-8111-111111111111';
      await queueFee(service);
      await service.updateBrixFeeForTest(requestId, (fee) {
        fee['state'] = BrixFeeState.sending.name;
        fee['idempotencyKey'] = idempotencyKey;
      });
      service.resetFeeStateForTest();
      String? resumedKey;

      await sendFee(service, (_, key) async {
        resumedKey = key;
        return {
          'success': true,
          'payment': {
            'status': 'PaymentStatus.pending',
            'paymentHash': feeHash,
          },
        };
      });

      expect(resumedKey, idempotencyKey);
      expect((await pendingFees()).single['state'], BrixFeeState.pendingSettlement.name);
      expect((await pendingFees()).single['feeInvoice'], feeInvoice);
    });

    test('mismatched failed status does not release a retry', () async {
      final service = BrixRelayService();
      await queueFee(service);
      await sendFee(service, (_, __) async => {
            'success': false,
            'mayStillSucceed': true,
          });

      await service.reconcileBrixFeeForTest(
        (await pendingFees()).single,
        (_) async => {
          'paid': false,
          'status': 'failed',
          'paymentHash': 'different-hash',
          'direction': 'send',
          'amountSats': '1405',
        },
      );

      expect(
        (await pendingFees()).single['state'],
        BrixFeeState.pendingSettlement.name,
      );
    });

    test('pending send remains queued for reconciliation', () async {
      final service = BrixRelayService();
      await queueFee(service);
      var payCalls = 0;

      await sendFee(service, (_, __) async {
        payCalls++;
        return {
          'success': true,
          'payment': {
            'status': 'PaymentStatus.pending',
            'paymentHash': feeHash,
          },
        };
      });

      final fees = await pendingFees();
      expect(payCalls, 1);
      expect(fees.single['state'], BrixFeeState.pendingSettlement.name);
      expect(fees.single['feePaymentHash'], feeHash);
      expect(fees.single['feeInvoice'], feeInvoice);
      expect(fees.single['idempotencyKey'], isNotEmpty);
    });

    test('timeout remains pending and restart does not blindly repay', () async {
      final service = BrixRelayService();
      await queueFee(service);
      var payCalls = 0;

      await sendFee(service, (_, __) async {
        payCalls++;
        return {'success': false, 'mayStillSucceed': true};
      });
      final pending = (await pendingFees()).single;
      await service.reconcileBrixFeeForTest(pending, (_) async => {
            'paid': false,
            'status': 'pending',
            'paymentHash': feeHash,
            'direction': 'send',
            'amountSats': '1405',
          });

      final fees = await pendingFees();
      expect(payCalls, 1);
      expect(fees.single['state'], BrixFeeState.pendingSettlement.name);
      expect(fees.single['feePaymentHash'], feeHash);
    });

    test('timeout followed by completed settles exactly once', () async {
      final service = BrixRelayService();
      await queueFee(service);
      var payCalls = 0;
      await sendFee(service, (_, __) async {
        payCalls++;
        return {'success': false, 'mayStillSucceed': true};
      });

      await service.reconcileBrixFeeForTest(
        (await pendingFees()).single,
        (_) async => {
          'paid': true,
          'status': 'completed',
          'paymentHash': feeHash,
          'direction': 'send',
          'amountSats': '1405',
        },
      );
      await sendFee(service, (_, __) async {
        payCalls++;
        return {'success': false, 'mayStillSucceed': true};
      });

      expect(payCalls, 1);
      expect(await pendingFees(), isEmpty);
    });

    test('missing SDK payment resumes only the same invoice and key', () async {
      final service = BrixRelayService();
      await queueFee(service);
      final keys = <String>[];
      final invoices = <String>[];
      var invoiceRequests = 0;

      Future<Map<String, dynamic>?> pay(String invoice, String key) async {
        invoices.add(invoice);
        keys.add(key);
        return {'success': false, 'mayStillSucceed': true};
      }

      await service.sendBrixFeeForTest(
        (await pendingFees()).single,
        getInvoice: () async {
          invoiceRequests++;
          return {'success': true, 'invoice': feeInvoice};
        },
        decodeInvoice: (_) async => {
          'success': true,
          'invoice': {'paymentHash': feeHash, 'amountSats': '1405'},
        },
        payInvoice: pay,
      );
      await service.reconcileBrixFeeForTest(
        (await pendingFees()).single,
        (_) async => {'paid': false, 'error': 'Payment not found'},
        resumeSameAttempt: (originalAttempt) async => service.sendBrixFeeForTest(
          originalAttempt,
          resumingMissingPayment: true,
          getInvoice: () async {
            invoiceRequests++;
            return {'success': true, 'invoice': 'different-invoice'};
          },
          decodeInvoice: (_) async => {
            'success': true,
            'invoice': {'paymentHash': feeHash, 'amountSats': '1405'},
          },
          payInvoice: pay,
        ),
      );

      expect(invoices, [feeInvoice, feeInvoice]);
      expect(keys[1], keys[0]);
      expect(invoiceRequests, 1);
    });

    test('failed resume preserves original invoice hash and key', () async {
      final service = BrixRelayService();
      await queueFee(service);
      String? originalKey;
      await sendFee(service, (_, key) async {
        originalKey = key;
        return {'success': false, 'mayStillSucceed': true};
      });
      final original = (await pendingFees()).single;

      await service.sendBrixFeeForTest(
        original,
        getInvoice: () async => {'success': true, 'invoice': 'new-invoice'},
        decodeInvoice: (_) async => {
          'success': true,
          'invoice': {'paymentHash': feeHash, 'amountSats': '1405'},
        },
        payInvoice: (_, __) async => {
          'success': false,
          'error': 'Invoice already paid (AlreadyExists)',
        },
        resumingMissingPayment: true,
      );

      final recovered = (await pendingFees()).single;
      expect(recovered['state'], BrixFeeState.pendingSettlement.name);
      expect(recovered['feeInvoice'], original['feeInvoice']);
      expect(recovered['feePaymentHash'], original['feePaymentHash']);
      expect(recovered['idempotencyKey'], originalKey);
    });

    test('decode failure keeps persisted attempt in protected pending state', () async {
      final service = BrixRelayService();
      await queueFee(service);
      await sendFee(service, (_, __) async => {
            'success': false,
            'mayStillSucceed': true,
          });
      final original = (await pendingFees()).single;

      await service.sendBrixFeeForTest(
        original,
        getInvoice: () async => {'success': true, 'invoice': 'new-invoice'},
        decodeInvoice: (_) async => {'success': false},
        payInvoice: (_, __) async => throw StateError('must not pay'),
        resumingMissingPayment: true,
      );

      final recovered = (await pendingFees()).single;
      expect(recovered['state'], BrixFeeState.pendingSettlement.name);
      expect(recovered['feeInvoice'], original['feeInvoice']);
      expect(recovered['feePaymentHash'], original['feePaymentHash']);
      expect(recovered['idempotencyKey'], original['idempotencyKey']);
    });

    test('ambiguous SDK error never resumes payment', () async {
      final service = BrixRelayService();
      await queueFee(service);
      await sendFee(service, (_, __) async => {
            'success': false,
            'mayStillSucceed': true,
          });
      var resumed = false;
      await service.reconcileBrixFeeForTest(
        (await pendingFees()).single,
        (_) async => {'paid': false, 'error': 'network unavailable'},
        resumeSameAttempt: (_) async => resumed = true,
      );

      expect(resumed, isFalse);
      expect((await pendingFees()).single['state'], BrixFeeState.pendingSettlement.name);
    });

    test('timeout followed by failed permits a later retry', () async {
      final service = BrixRelayService();
      await queueFee(service);
      await sendFee(service, (_, __) async => {
            'success': false,
            'mayStillSucceed': true,
          });

      await service.reconcileBrixFeeForTest(
        (await pendingFees()).single,
        (_) async => {
          'paid': false,
          'status': 'failed',
          'paymentHash': feeHash,
          'direction': 'send',
          'amountSats': '1405',
        },
      );

      final fees = await pendingFees();
      expect(fees.single['state'], BrixFeeState.awaitingReceipt.name);
      expect(fees.single.containsKey('feePaymentHash'), isFalse);
      expect(fees.single.containsKey('feeInvoice'), isFalse);
    });

    test('definitive failure rotates idempotency key on the next real retry', () async {
      final service = BrixRelayService();
      await queueFee(service);
      final keys = <String>[];
      await sendFee(service, (_, key) async {
        keys.add(key);
        return {
          'success': true,
          'payment': {
            'status': 'PaymentStatus.failed',
            'paymentHash': feeHash,
            'amount': '1405',
          },
        };
      });
      await sendFee(service, (_, key) async {
        keys.add(key);
        return {
          'success': true,
          'payment': {
            'status': 'PaymentStatus.pending',
            'paymentHash': feeHash,
            'amount': '1405',
          },
        };
      });

      expect(keys, hasLength(2));
      expect(keys[1], isNot(keys[0]));
    });

    test('wrong invoice amount never calls payInvoice', () async {
      final service = BrixRelayService();
      await queueFee(service);
      var payCalls = 0;
      await service.sendBrixFeeForTest(
        (await pendingFees()).single,
        getInvoice: () async => {'success': true, 'invoice': feeInvoice},
        decodeInvoice: (_) async => {
          'success': true,
          'invoice': {'paymentHash': feeHash, 'amountSats': '1406'},
        },
        payInvoice: (_, __) async {
          payCalls++;
          return null;
        },
      );

      expect(payCalls, 0);
      expect((await pendingFees()).single['state'], BrixFeeState.awaitingReceipt.name);
    });

    test('settlement persists paid marker before removing queue entry', () async {
      final service = BrixRelayService();
      await queueFee(service);
      await sendFee(service, (_, __) async => {
            'success': true,
            'payment': {
              'status': 'PaymentStatus.completed',
              'paymentHash': feeHash,
              'amount': '1405',
            },
          });

      expect(await pendingFees(), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('brix_paid_fee_request_ids'), [requestId]);
    });

    test('concurrent sends make at most one payment call', () async {
      final service = BrixRelayService();
      await queueFee(service);
      var payCalls = 0;
      final releasePay = Completer<void>();

      Future<Map<String, dynamic>?> pay(_, __) async {
        payCalls++;
        await releasePay.future;
        return {
          'success': true,
          'payment': {
            'status': 'PaymentStatus.pending',
            'paymentHash': feeHash,
          },
        };
      }

      final first = sendFee(service, pay);
      final second = sendFee(service, pay);
      releasePay.complete();
      await Future.wait([first, second]);

      expect(payCalls, 1);
      expect((await pendingFees()).single['state'], BrixFeeState.pendingSettlement.name);
    });

    test('storage operations are serialized without losing distinct entries', () async {
      final service = BrixRelayService();
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();

      final first = service.runWithFeeStorageLock(() async {
        firstStarted.complete();
        await releaseFirst.future;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('first', 'kept');
      });
      await firstStarted.future;
      final second = service.runWithFeeStorageLock(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('second', 'kept');
      });
      releaseFirst.complete();
      await Future.wait([first, second]);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('first'), 'kept');
      expect(prefs.getString('second'), 'kept');
    });
  });
}

class FailingWritePreferences implements SharedPreferences {
  FailingWritePreferences(this._delegate, {this.throwOnWrite = false});

  final SharedPreferences _delegate;
  final bool throwOnWrite;

  @override
  Future<bool> setString(String key, String value) {
    if (throwOnWrite) throw StateError('simulated storage failure');
    return Future.value(false);
  }

  @override
  String? getString(String key) => _delegate.getString(key);

  @override
  List<String>? getStringList(String key) => _delegate.getStringList(key);

  @override
  Future<bool> setStringList(String key, List<String> value) {
    if (throwOnWrite) throw StateError('simulated storage failure');
    return Future.value(false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

import 'dart:async';

import 'package:bro_app/providers/breez_provider_export.dart';
import 'package:bro_app/providers/order_provider.dart';
import 'package:bro_app/screens/onchain_payment_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// No SDK initialization, storage access or payment polling in these UI tests.
class _UnusedBreezProvider extends ChangeNotifier implements BreezProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedOrderProvider extends ChangeNotifier implements OrderProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _address = 'bc1qexplorertest';
const _launcher = MethodChannel('plugins.flutter.io/url_launcher');
const _explorerError = 'Não foi possível abrir o explorador. Tente novamente.';

Future<void> _pumpPaymentScreen(WidgetTester tester) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<BreezProvider>.value(
            value: _UnusedBreezProvider()),
        ChangeNotifierProvider<OrderProvider>.value(
            value: _UnusedOrderProvider()),
      ],
      child: const MaterialApp(
        home: OnchainPaymentScreen(
          address: _address,
          btcAmount: 0.00001,
          totalBrl: 5,
          amountSats: 1000,
          orderId: 'explorer-test',
        ),
      ),
    ),
  );
  await tester.ensureVisible(find.byTooltip('Abrir no explorador'));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(_launcher, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('opens the address URI in an external application',
      (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_launcher, (call) async {
      calls.add(call);
      return true;
    });
    await _pumpPaymentScreen(tester);

    await tester.tap(find.byTooltip('Abrir no explorador'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(calls, hasLength(1));
    expect(calls.single.method, 'launch');
    expect(
        calls.single.arguments,
        containsPair(
          'url',
          'https://mempool.space/address/$_address',
        ));
    // The MethodChannel adapter maps externalApplication to these flags.
    expect(calls.single.arguments, containsPair('useSafariVC', false));
    expect(calls.single.arguments, containsPair('useWebView', false));
    expect(calls.single.arguments, containsPair('universalLinksOnly', false));
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shows error feedback when the launcher throws', (tester) async {
    messenger.setMockMethodCallHandler(_launcher, (call) async {
      throw PlatformException(code: 'launch_failed', message: 'Test failure');
    });
    await _pumpPaymentScreen(tester);

    await tester.tap(find.byTooltip('Abrir no explorador'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text(_explorerError), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final throws in [false, true]) {
    testWidgets(
        'ignores pending ${throws ? 'exception' : 'false'} after unmount',
        (tester) async {
      final result = Completer<bool>();
      var launched = false;
      messenger.setMockMethodCallHandler(_launcher, (call) {
        launched = true;
        return result.future;
      });
      await _pumpPaymentScreen(tester);
      await tester.tap(find.byTooltip('Abrir no explorador'));
      await tester.pump();
      expect(launched, isTrue);
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));

      if (throws) {
        result.completeError(PlatformException(code: 'launch_failed'));
      } else {
        result.complete(false);
      }
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(find.byType(SnackBar), findsNothing);
    });
  }

  testWidgets('still copies the address without launching the explorer',
      (tester) async {
    final clipboardCalls = <MethodCall>[];
    final launcherCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      clipboardCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(_launcher, (call) async {
      launcherCalls.add(call);
      return true;
    });
    await _pumpPaymentScreen(tester);

    await tester.tap(find.byIcon(Icons.copy).first);
    await tester.pump(const Duration(milliseconds: 300));

    final copied =
        clipboardCalls.where((call) => call.method == 'Clipboard.setData');
    expect(copied, hasLength(1));
    expect(copied.single.arguments, {'text': _address});
    expect(find.text('Endereço copiado!'), findsOneWidget);
    expect(launcherCalls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shows error feedback when the explorer cannot be launched',
      (tester) async {
    messenger.setMockMethodCallHandler(_launcher, (call) async => false);
    await _pumpPaymentScreen(tester);

    await tester.tap(find.byTooltip('Abrir no explorador'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text(_explorerError), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

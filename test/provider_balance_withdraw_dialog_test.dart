import 'dart:async';

import 'package:bro_app/l10n/app_localizations.dart';
import 'package:bro_app/models/provider_balance.dart';
import 'package:bro_app/providers/breez_provider_export.dart';
import 'package:bro_app/providers/provider_balance_provider.dart';
import 'package:bro_app/screens/provider_balance_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// No SDK initialization, persistence, network, or real withdrawals.
class FakeBalanceProvider extends ProviderBalanceProvider {
  final result = Completer<bool>();
  double? requestedAmount;
  String? requestedAddress;

  @override
  ProviderBalance get balance => ProviderBalance(
        providerId: 'test-provider',
        availableBalanceSats: 10000,
        totalEarnedSats: 10000,
        transactions: [],
        updatedAt: DateTime(2026),
      );

  @override
  Future<void> initialize(String providerId) async {}

  @override
  String get error => 'Falha de saque simulada';

  @override
  Future<bool> withdrawOnchain({
    required double amountSats,
    required String address,
  }) {
    requestedAmount = amountSats;
    requestedAddress = address;
    return result.future;
  }
}

class FakeBreezProvider extends BreezProvider {
  @override
  bool get isInitialized => false;
}

void main() {
  final l = AppLocalizations(const Locale('pt'));
  for (final sent in [true, false]) {
    testWidgets('shows feedback for $sent after withdrawal dialog is disposed',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final balance = FakeBalanceProvider();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<ProviderBalanceProvider>(
              create: (_) => balance),
          ChangeNotifierProvider<BreezProvider>(
              create: (_) => FakeBreezProvider()),
        ],
        child: const MaterialApp(home: ProviderBalanceScreen()),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.t('prov_bal_withdraw_onchain')));
      await tester.pumpAndSettle();
      final dialogElement = tester.element(find.byType(AlertDialog));
      await tester.enterText(find.byType(TextField).at(0), '1000');
      const address = 'BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4';
      await tester.enterText(find.byType(TextField).at(1), address);
      await tester
          .tap(find.widgetWithText(ElevatedButton, l.t('prov_bal_withdraw')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(dialogElement.mounted, isFalse);
      expect(balance.requestedAmount, 1000);
      expect(balance.requestedAddress, address.toLowerCase());
      expect(find.byType(SnackBar), findsNothing);

      balance.result.complete(sent);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
          find.text(sent
              ? l.t('prov_bal_withdraw_sent')
              : 'Erro: Exception: Falha de saque simulada'),
          findsOneWidget);
      expect(tester.widget<SnackBar>(find.byType(SnackBar)).backgroundColor,
          sent ? Colors.green : Colors.red);
    });
  }
}

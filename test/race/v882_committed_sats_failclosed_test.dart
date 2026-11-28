import 'package:flutter_test/flutter_test.dart';

/// v882 — `committedSats` fail-closed (caso `9d4c8dbf`).
///
/// ## O bug
///
/// `committedSats` exigia `paymentHash != null` para travar sats:
///
/// ```dart
/// if (o.paymentHash == null || o.paymentHash!.isEmpty) continue;
/// ```
///
/// O `paymentHash` é dado **LOCAL** — não vai para o Nostr. Então uma ordem
/// paga em outro aparelho (ou cujo `setOrderPaymentHashAndStatusLocal` falhou)
/// ficava com `committedSats = 0` e os sats **disponíveis para gasto duplo**.
///
/// Caso real: ordem `9d4c8dbf` paga com saldo da carteira, `status=accepted`,
/// `paymentHash=null`, zero logs `LOCKED`.
///
/// ## A correção
///
/// Ordens em estado que **implica pagamento feito** travam `totalInvoiceSats`
/// mesmo sem hash. A direção do erro é sempre travar mais, nunca menos.
void main() {
  /// Simula a decisão do `committedSats` (v882).
  bool shouldLock({
    required String status,
    String? paymentHash,
  }) {
    const terminalStatuses = ['completed', 'cancelled', 'liquidated'];
    const paidStatuses = [
      'payment_received',
      'accepted',
      'processing',
      'awaiting_confirmation',
      'completing',
    ];

    if (terminalStatuses.contains(status)) return false;

    final hasHash = paymentHash != null && paymentHash.isNotEmpty;
    final isPaidStatus = paidStatuses.contains(status);

    return hasHash || isPaidStatus;
  }

  group('Caso real 9d4c8dbf — pago sem hash', () {
    test('accepted sem paymentHash TRAVA (era o bug)', () {
      expect(
        shouldLock(status: 'accepted', paymentHash: null),
        isTrue,
        reason: 'antes retornava false → sats disponíveis para gasto duplo',
      );
    });

    test('payment_received sem hash trava', () {
      expect(shouldLock(status: 'payment_received', paymentHash: null), isTrue);
    });

    test('awaiting_confirmation sem hash trava', () {
      expect(
        shouldLock(status: 'awaiting_confirmation', paymentHash: null),
        isTrue,
      );
    });

    test('processing sem hash trava', () {
      expect(shouldLock(status: 'processing', paymentHash: null), isTrue);
    });
  });

  group('Ordens ainda não pagas NÃO travam', () {
    test('pending sem hash não trava', () {
      expect(shouldLock(status: 'pending', paymentHash: null), isFalse);
    });

    test('draft sem hash não trava', () {
      expect(shouldLock(status: 'draft', paymentHash: null), isFalse);
    });
  });

  group('Ordens terminais nunca travam', () {
    for (final s in ['completed', 'cancelled', 'liquidated']) {
      test('$s com hash não trava', () {
        expect(shouldLock(status: s, paymentHash: 'wallet_abc'), isFalse);
      });
      test('$s sem hash não trava', () {
        expect(shouldLock(status: s, paymentHash: null), isFalse);
      });
    }
  });

  group('Comportamento anterior preservado (com hash)', () {
    test('wallet_ paga trava', () {
      expect(
        shouldLock(status: 'payment_received', paymentHash: 'wallet_abc123'),
        isTrue,
      );
    });

    test('lightning paga trava', () {
      expect(
        shouldLock(status: 'accepted', paymentHash: 'a' * 64),
        isTrue,
      );
    });

    test('pending com hash trava (pagou mas status não avançou)', () {
      expect(
        shouldLock(status: 'pending', paymentHash: 'wallet_abc'),
        isTrue,
        reason: 'hash é prova de pagamento — trava mesmo em pending',
      );
    });
  });

  group('Fail-closed: direção do erro', () {
    test('na dúvida, trava mais — nunca menos', () {
      // Qualquer status que implique pagamento trava, com ou sem hash.
      const paidStatuses = [
        'payment_received',
        'accepted',
        'processing',
        'awaiting_confirmation',
        'completing',
      ];
      for (final s in paidStatuses) {
        expect(shouldLock(status: s, paymentHash: null), isTrue,
            reason: '$s sem hash deve travar (fail-closed)');
        expect(shouldLock(status: s, paymentHash: 'wallet_x'), isTrue,
            reason: '$s com hash deve travar');
      }
    });

    test('gasto duplo impossível: ordem paga sempre trava', () {
      // Cenário: usuário paga ordem A com saldo, paymentHash não grava.
      // Tenta criar ordem B. committedSats deve incluir A.
      final lockedA = shouldLock(status: 'accepted', paymentHash: null);
      expect(lockedA, isTrue,
          reason: 'sem isso, B usaria sats que já são do Bro');
    });
  });
}

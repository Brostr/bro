import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform, visibleForTesting;
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:bro_app/services/brix_service.dart';
import 'package:bro_app/services/api_service.dart';
import 'package:bro_app/services/storage_service.dart';
import 'package:bro_app/services/secure_storage_service.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:bro_app/services/push_diag.dart';
import 'package:bro_app/services/lnaddress_service.dart';
import 'package:bro_app/providers/breez_provider.dart';
import 'package:bro_app/config.dart';
import 'package:bro_app/config/payment_methods.dart';

enum BrixFeeState {
  awaitingPaymentHash,
  awaitingReceipt,
  sending,
  pendingSettlement;

  static BrixFeeState fromStorage(Object? value) {
    return values.firstWhere(
      (state) => state.name == value,
      orElse: () => BrixFeeState.awaitingReceipt,
    );
  }
}

/// Global BRIX invoice relay service.
/// Polls the BRIX server for incoming invoice requests and auto-generates
/// invoices via the user's Breez wallet. Runs whenever the app is in foreground.
/// Also retries queued outgoing BRIX payments when recipients come online.
class BrixRelayService {
  static final BrixRelayService _instance = BrixRelayService._internal();
  factory BrixRelayService() => _instance;
  BrixRelayService._internal();

  final _brixService = BrixService();
  final _storage = StorageService();

  Timer? _pollTimer;
  bool _running = false;
  String? _pubkey;
  String? _brixUsername;
  BuildContext? _context;
  bool _fcmRegistered = false;
  bool _backendFcmRegistered = false;
  // vSEC-fix: true quando o servidor respondeu 404 ("sem conta BRIX"). Nesse
  // caso o retry é INÚTIL (o usuário simplesmente não usa BRIX) e queimava
  // bateria/rede a cada poll para sempre. Quem TEM BRIX recebe 200 e segue
  // o fluxo normal — este flag só zera o retry de quem não tem conta.
  bool _brixNotAUser = false;

  /// Callback for when a queued outgoing payment is completed.
  void Function(String recipient, int amountSats)? onQueuedPaymentCompleted;

  int _fcmRetryCount = 0;

  /// Pure, testable anti-double-spend decision for the outgoing queue.
  /// Returns the first paymentHash in [hashes] that [check] reports as settled,
  /// or null if none settled. A per-hash check error is treated as "not
  /// settled" so we never SKIP a payment on a transient error (we would rather
  /// re-check next cycle than risk not paying at all — the fresh-invoice guard
  /// only blocks paying AGAIN when a settlement is positively confirmed).
  @visibleForTesting
  static Future<String?> firstSettledHash(
    List<String> hashes,
    Future<bool> Function(String hash) check,
  ) async {
    for (final h in hashes) {
      try {
        if (await check(h)) return h;
      } catch (_) {
        // Ignore transient check errors; treat as not-yet-settled.
      }
    }
    return null;
  }

  /// Ensure FCM token is registered with BRIX server (idempotent).
  /// Retries automatically on failure until successful.
  /// vSEC-fix: o BRIX (quando sem conta → _brixNotAUser) NÃO bloqueia o
  /// registro no backend principal — são independentes.
  Future<void> _ensureFcmRegistered() async {
    final brixDone = _fcmRegistered || _brixNotAUser;
    if (brixDone && _backendFcmRegistered) return;
    try {
      _pubkey ??= await _storage.getNostrPublicKey();
      if (_pubkey == null || _pubkey!.isEmpty) {
        PushDiag.log('relay: no pubkey');
        return;
      }
      // iOS: APNS token must be ready before FCM can provide a token
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        String? apns = await FirebaseMessaging.instance.getAPNSToken();
        // v524: aggressive APNS wait within a single attempt (up to 8s).
        // On iOS, APNS can take 10-30s on cold starts and the old code bailed immediately.
        if (apns == null) {
          for (int i = 0; i < 4 && apns == null; i++) {
            await Future.delayed(const Duration(seconds: 2));
            apns = await FirebaseMessaging.instance.getAPNSToken();
          }
        }
        if (apns == null) {
          if (_fcmRetryCount % 5 == 0) {
            broLog('[BRIX-RELAY] iOS: APNS still not ready after 8s (retry $_fcmRetryCount)');
            PushDiag.log('relay: APNS null retry=$_fcmRetryCount');
          }
          _fcmRetryCount++;
          return;
        }
      }
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) {
        _fcmRetryCount++;
        broLog('[BRIX-RELAY] FCM token is null (retry $_fcmRetryCount) — cannot register');
        PushDiag.log('relay: FCM token NULL retry=$_fcmRetryCount');
        return;
      }

      // Register with BRIX server
      // vSEC-fix: pular se o servidor já disse 404 (sem conta BRIX) — evita
      // retry infinito. Se o usuário CRIAR uma conta BRIX depois, o flag é
      // resetado em start()/resume e o registro volta a funcionar.
      if (!_fcmRegistered && !_brixNotAUser) {
        // Ensure NIP-98 credentials are loaded before signing the request
        await _brixService.initCredentials();
        final ok = await _brixService.registerPushToken(token, _pubkey!);
        if (ok == true) {
          _fcmRegistered = true;
          _fcmRetryCount = 0;
          broLog('[BRIX-RELAY] FCM token registered successfully (BRIX)');
          // Auto-claim any web-created BRIX accounts with same email
          final linked = await _brixService.claimWebAccounts(_pubkey!);
          if (linked.isNotEmpty) {
            broLog('[BRIX-RELAY] Auto-linked web accounts: ${linked.join(", ")}');
          }
        } else if (ok == null) {
          // 404 permanente — sem conta BRIX. Marcar e NÃO tentar de novo.
          _brixNotAUser = true;
          _fcmRetryCount = 0;
          broLog('[BRIX-RELAY] Sem conta BRIX (404) — desativando retry de FCM BRIX');
        } else {
          _fcmRetryCount++;
          broLog('[BRIX-RELAY] BRIX FCM registration failed (attempt $_fcmRetryCount)');
        }
      }

      // Register with main backend for order_update push notifications
      if (!_backendFcmRegistered) {
        try {
          // v633: assert providerEnabled=true when in provider mode. The
          // reliable retry loop previously registered WITHOUT the flag, so if
          // the one-shot startup registration failed (network unavailable in
          // the ~8s startup window), the provider NEVER got 'Nova ordem'
          // broadcasts — the backend preserves the (absent → false) flag.
          // Now the loop itself enforces provider status.
          final isProvider = await SecureStorageService.isProviderMode(userPubkey: _pubkey);
          final ok = isProvider
              ? await ApiService().registerPushToken(token, providerEnabled: true)
              : await ApiService().registerPushToken(token);
          if (ok) {
            _backendFcmRegistered = true;
            broLog('[BRIX-RELAY] FCM token registered successfully (backend, provider=$isProvider)');
            PushDiag.log('relay: backend register OK provider=$isProvider');
            if (isProvider) {
              unawaited(_resyncProviderFilters());
            }
          } else {
            broLog('[BRIX-RELAY] Backend FCM registration returned false');
            PushDiag.log('relay: backend register FALSE');
          }
        } catch (e) {
          broLog('[BRIX-RELAY] Backend FCM registration error: $e');
          PushDiag.log('relay: backend register ERR ${e.toString().substring(0, e.toString().length > 60 ? 60 : e.toString().length)}');
        }
      }
    } catch (e) {
      _fcmRetryCount++;
      broLog('[BRIX-RELAY] FCM registration error (attempt $_fcmRetryCount): $e');
    }
  }

  /// v524: Ask the backend whether our token is actually stored.
  /// If not, flip the flag so the next poll re-registers.
  Future<void> _verifyBackendRegistration() async {
    try {
      final registered = await ApiService().diagnosePushToken();
      PushDiag.log('relay: diagnose=${registered ?? "null"}');
      if (registered == false) {
        broLog('[BRIX-RELAY] Backend says NOT registered — forcing re-registration');
        _backendFcmRegistered = false;
      }
    } catch (e) {
      PushDiag.log('relay: diagnose ERR $e');
    }
  }

  /// v633: Re-send provider payment-method + accepted-currency filters to the
  /// backend. The UI syncs these fire-and-forget only when the filter changes;
  /// if that single call failed (network), the provider could stop receiving
  /// matching 'Nova ordem' broadcasts. Re-asserting on every fresh backend
  /// registration heals it automatically (no user action needed).
  Future<void> _resyncProviderFilters() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('bro_provider_selected_methods');
      if (raw == null || raw.isEmpty) return; // nothing saved → backend keeps 'all'
      final methods = (jsonDecode(raw) as List).map((e) => e.toString()).toList();
      if (methods.isEmpty) return;
      await ApiService().setProviderPaymentMethods(methods);
      final accepted = <String>[];
      for (final g in PaymentMethods.kGroups) {
        if (g.currency == 'BRL') continue; // BRL always delivered by backend
        if (g.ids.every(methods.contains)) accepted.add(g.currency);
      }
      await ApiService().setProviderAcceptedCurrencies(accepted);
      PushDiag.log('relay: provider filters resynced (methods=${methods.length}, cur=${accepted.length})');
    } catch (e) {
      broLog('[BRIX-RELAY] provider filter resync failed: $e');
    }
  }

  /// v633: Periodic re-assert of provider status. Protects against the backend
  /// dropping the providerEnabled flag on restart / token rotation. Idempotent.
  Future<void> _reassertProviderStatusPeriodic() async {
    try {
      if (_pubkey == null || _pubkey!.isEmpty) return;
      final isProvider = await SecureStorageService.isProviderMode(userPubkey: _pubkey);
      if (!isProvider) return;
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      await ApiService().registerPushToken(token, providerEnabled: true);
      await _resyncProviderFilters();
      PushDiag.log('relay: periodic provider re-assert OK');
    } catch (e) {
      broLog('[BRIX-RELAY] periodic provider re-assert failed: $e');
    }
  }

  /// Start the relay service. Call from main app after login.
  void start(BuildContext context) {
    _context = context;
    if (_running) {
      broLog('[BRIX-RELAY] start() called but already running');
      return;
    }
    _running = true;
    _fcmRegistered = false; // Reset on start so we always try to register
    _backendFcmRegistered = false;
    _brixNotAUser = false; // vSEC-fix: re-tentar BRIX — usuário pode ter criado conta
    _pollTimer?.cancel();
    // v535: intervalo de 5s (antes 1.5s). 1.5s era excessivo e causava
    // lentidao na UI por fazer 2 chamadas HTTP a cada polling (invoice requests
    // + pending payments). FCM push faz triggerPoll() imediato quando chega
    // pagamento, entao 5s de fallback eh suficiente.
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
    _poll(); // immediate first check
    _ensureFcmRegistered();
    broLog('[BRIX-RELAY] Service started');
  }

  /// Restart the relay (e.g. after app resumes from background).
  void restart(BuildContext context) {
    _context = context;
    _pollTimer?.cancel();
    _running = true;
    _fcmRegistered = false; // Force re-registration after resume (token may have rotated)
    _backendFcmRegistered = false;
    _brixNotAUser = false; // vSEC-fix: re-tentar BRIX — usuário pode ter criado conta
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
    _poll();
    _ensureFcmRegistered();
    broLog('[BRIX-RELAY] Service restarted (resume)');
  }

  /// Stop the relay service.
  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _running = false;
    _context = null;
    broLog('[BRIX-RELAY] Service stopped');
  }

  /// Trigger an immediate poll cycle. Called when FCM push arrives.
  void triggerPoll() {
    if (_running && _context != null) {
      broLog('[BRIX-RELAY] FCM wake-up → immediate poll');
      _poll();
    }
  }

  /// Reset FCM registration state so next poll re-registers.
  /// Called when Firebase rotates the FCM token.
  void resetFcmRegistration() {
    _fcmRegistered = false;
    _backendFcmRegistered = false;
    _fcmRetryCount = 0;
    _brixNotAUser = false; // vSEC-fix: token rotation = nova chance p/ BRIX
  }

  int _pollCount = 0;
  bool _polling = false;

  Future<void> _poll() async {
    if (!_running || _context == null) return;
    if (_polling) return; // Prevent concurrent polls
    _polling = true;
    _pollCount++;

    try {
      await _pollInner();
    } finally {
      _polling = false;
    }
  }

  Future<void> _pollInner() async {

    // Log every 20th poll (~30s) for visibility
    if (_pollCount % 20 == 1) {
      broLog('[BRIX-RELAY] Poll #$_pollCount (running=$_running, fcmRegistered=$_fcmRegistered, pubkey=${_pubkey?.substring(0, 8) ?? "null"})');
    }

    // Retry FCM registration every ~30s until successful.
    // v620: poll passou de 1.5s→5s (v535) mas o módulo continuava 20, o que
    // esticou o retry real para ~100s. % 6 com poll de 5s = ~30s (intenção original).
    if ((!_fcmRegistered || !_backendFcmRegistered) && _pollCount % 6 == 1) {
      _ensureFcmRegistered();
    }

    // v524: A cada ~2min, verifica se o backend REALMENTE tem nosso token.
    // Protege contra deregistro silencioso (FCM rotaciona sem disparar
    // onTokenRefresh, ou servidor descarta tokens antigos).
    // v620: % 24 com poll de 5s = ~120s (antes % 80 = ~6,7min por causa do 5s).
    if (_backendFcmRegistered && _pollCount % 24 == 1) {
      unawaited(_verifyBackendRegistration());
    }

    // v633: A cada ~10min, re-afirma providerEnabled + filtros no backend.
    // Protege contra o backend perder a flag em restart/rotacao de token, o
    // que silenciava os broadcasts de 'Nova ordem' (causa das ordens perdidas).
    if (_backendFcmRegistered && _pollCount % 120 == 61) {
      unawaited(_reassertProviderStatusPeriodic());
    }

    try {
      // Get pubkey lazily
      _pubkey ??= await _storage.getNostrPublicKey();
      if (_pubkey == null || _pubkey!.isEmpty) {
        if (_pollCount % 20 == 1) {
          broLog('[BRIX-RELAY] ⚠ No pubkey in storage — relay inactive');
        }
        return;
      }

      // Load BRIX username lazily (needed to filter requests per-account)
      if (_brixUsername == null) {
        try {
          final prefs = await SharedPreferences.getInstance();
          final raw = prefs.getString('brix_cached');
          if (raw != null) {
            final cached = jsonDecode(raw) as Map<String, dynamic>;
            _brixUsername = cached['username'] as String?;
            if (_brixUsername != null) {
              broLog('[BRIX-RELAY] Loaded BRIX username: $_brixUsername');
            }
          }
        } catch (_) {}
      }

      // Init NIP-98 credentials lazily (loads private key for signed auth)
      await _brixService.initCredentials();

      // Check if user has active BRIX invoice requests (online flow)
      final requests = await _brixService.getInvoiceRequests(_pubkey!, username: _brixUsername);

      final breezProvider = _context!.read<BreezProvider>();

      for (final request in requests) {
        broLog('⚡ [BRIX-RELAY] Generating invoice: ${request.amountSats} sats (request=${request.id})${request.comment != null ? ' memo: ${request.comment}' : ''}');

        // Generate invoice for FULL amount (LNURL wallets verify amount match)
        final description = request.comment != null && request.comment!.isNotEmpty
            ? 'BRIX: ${request.comment}'
            : 'BRIX Payment';
        final invoiceResult = await breezProvider.createInvoice(
          amountSats: request.amountSats,
          description: description,
        );

        if (invoiceResult == null) {
          broLog('❌ [BRIX-RELAY] createInvoice returned null for ${request.amountSats} sats');
          continue;
        }

        if (invoiceResult['success'] != true) {
          broLog('❌ [BRIX-RELAY] createInvoice FAILED for ${request.amountSats} sats: ${invoiceResult['error']}');
          continue;
        }

        if (invoiceResult['success'] == true) {
          final bolt11 = invoiceResult['bolt11'] as String? ??
              invoiceResult['invoice'] as String?;
          if (bolt11 != null) {
            final ok = await _brixService.submitInvoice(
                request.id, bolt11, _pubkey!);
            broLog(
                '⚡ [BRIX-RELAY] Invoice ${ok ? "submitted" : "failed"} for ${request.amountSats} sats');

            // Persist locally so it appears in wallet even if SDK forgets
            if (ok) {
              persistBrixPayment(
                amountSats: request.amountSats,
                description: description,
                paymentHash: invoiceResult['paymentHash'] as String?,
              );
            }

            if (ok) {
              final paymentHash = invoiceResult['paymentHash'] as String?;
              final feeSats = calculateBrixFee(request.amountSats);
              if (feeSats > 0) {
                await _queueBrixFee(
                  requestId: request.id,
                  paymentHash: paymentHash,
                  bolt11: bolt11,
                  amountSats: request.amountSats,
                  feeSats: feeSats,
                );
              }
            }
          }
        }
      }

      // ── Claim pending offline payments ──
      // vSEC-fix: pular se o servidor já disse 404 (sem conta BRIX). Sem isso,
      // um usuário sem BRIX fazia uma chamada HTTP a cada poll (5s) que sempre
      // retornava 404 — ruído de rede/log e bateria. Quem TEM BRIX (200) segue
      // o fluxo normal; o flag é resetado em start()/restart()/token-rotation.
      if (!_brixNotAUser) {
        await _loadClaimedPayments(); // v661: garantir que o set veio do disco
        final pendingPayments = await _brixService.getPendingPayments(_pubkey!);
        for (final payment in pendingPayments) {
        if (_claimedPayments.contains(payment.id)) continue;
        _claimedPayments.add(payment.id);
        await _persistClaimedPayments(); // v661: gravar ANTES de criar a invoice

        broLog('💰 [BRIX-RELAY] Claiming offline payment: ${payment.amountSats} sats');

        final offlineDesc = payment.senderNote != null && payment.senderNote!.isNotEmpty
            ? 'BRIX: ${payment.senderNote}'
            : 'BRIX Payment';
        // v749 (CRIT-03 fase 2): vincular a invoice a este pagamento —
        // pede o nonce ao servidor e embute na descrição. Se falhar (rede),
        // segue sem nonce (servidor aceita até CLAIM_NONCE_REQUIRED=1).
        String claimDesc = offlineDesc;
        final nonce = await _brixService.getClaimNonce(payment.id, _pubkey!);
        if (nonce != null && nonce.isNotEmpty) {
          claimDesc = '$offlineDesc #$nonce';
        }
        final invoiceResult = await breezProvider.createInvoice(
          amountSats: payment.amountSats,
          description: claimDesc,
        );

        if (invoiceResult != null && invoiceResult['success'] == true) {
          final bolt11 = invoiceResult['bolt11'] as String? ??
              invoiceResult['invoice'] as String?;
          if (bolt11 != null) {
            final claimed = await _brixService.claimPayment(
                payment.id, bolt11, _pubkey!);
            broLog(
                '💰 [BRIX-RELAY] Claim ${claimed ? "success" : "failed"} for ${payment.amountSats} sats');
            if (claimed) {
              persistBrixPayment(
                amountSats: payment.amountSats,
                grossAmountSats: payment.displayGross,
                feeSats: payment.feeSats,
                description: offlineDesc,
                paymentHash: invoiceResult['paymentHash'] as String?,
              );
            }
            if (!claimed) {
              _claimedPayments.remove(payment.id);
              await _persistClaimedPayments(); // v661: desfazer no disco também
            }
          } else {
            _claimedPayments.remove(payment.id);
            await _persistClaimedPayments();
          }
        } else {
          _claimedPayments.remove(payment.id);
          await _persistClaimedPayments();
        }
        } // end for (pendingPayments)
      } // end if (!_brixNotAUser)
    } catch (e) {
      // Log errors periodically (every ~30s) to avoid spam but still visible
      if (_pollCount % 20 == 1) {
        broLog('[BRIX-RELAY] Poll error: $e');
      }
    }

    await _processBrixFees();

    // Retry queued outgoing BRIX payments (async, non-blocking)
    _scheduleRetryIfNeeded();
  }

  /// Schedule retry in a separate async task so it doesn't block the poll loop.
  /// The 25+ second LNURL callback would otherwise block incoming invoice handling.
  void _scheduleRetryIfNeeded() {
    if (_retrying) return;
    final now = DateTime.now();
    if (_lastRetryCheck != null &&
        now.difference(_lastRetryCheck!).inSeconds < _retryIntervalSeconds) {
      return;
    }
    // Fire and forget — don't await
    _retryOutgoingPayments();
  }

  // Track fees already sent to prevent duplicates.
  // v635: now PERSISTENT across restarts (was in-memory only, so a restart
  // could re-pay the 0.5% BRIX fee for a still-pending request id).
  final Set<String> _paidFees = {};
  static const _paidFeesKey = 'brix_paid_fee_request_ids';
  static const _settledFeeHashesKey = 'brix_settled_fee_payment_hashes';
  static const _settledFeeLinksKey = 'brix_settled_fee_links';
  bool _paidFeesLoaded = false;
  // v661: Track claims to prevent duplicates — agora PERSISTENTE. Antes era só
  // em memória: se o app crashava/fechava entre marcar o pagamento como
  // "claimed" e o servidor confirmar, o set se perdia no restart e o app
  // reivindicava o MESMO pagamento offline de novo (risco de receber 2x).
  // Mesmo padrão do _paidFees.
  final Set<String> _claimedPayments = {};
  static const _claimedPaymentsKey = 'brix_claimed_payment_ids';
  bool _claimedPaymentsLoaded = false;

  Future<void> _loadPaidFees() async {
    if (_paidFeesLoaded) return;
    _paidFeesLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_paidFeesKey);
      if (raw != null) _paidFees.addAll(raw);
    } catch (_) {}
  }

  Future<void> _persistPaidFees() async {
    final prefs = await _feePrefs();
    // Bound growth: keep the most recent ids (insertion-ordered Set).
    var ids = _paidFees.toList();
    if (ids.length > 500) {
      ids = ids.sublist(ids.length - 500);
      _paidFees
        ..clear()
        ..addAll(ids);
    }
    final saved = await prefs.setStringList(_paidFeesKey, ids);
    if (!saved) throw StateError('Could not persist settled BRIX fees');
  }

  static Future<Set<String>> getSettledFeePaymentHashes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_settledFeeHashesKey) ?? const <String>[]).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<Map<String, Map<String, dynamic>>> getSettledFeeLinks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final decoded = jsonDecode(prefs.getString(_settledFeeLinksKey) ?? '{}');
      if (decoded is! Map) return <String, Map<String, dynamic>>{};
      return decoded.map((key, value) => MapEntry(
          key.toString(), Map<String, dynamic>.from(value as Map)));
    } catch (_) {
      return <String, Map<String, dynamic>>{};
    }
  }

  // v661: carregar/persistir os claims (mesmo padrão do _paidFees).
  Future<void> _loadClaimedPayments() async {
    if (_claimedPaymentsLoaded) return;
    _claimedPaymentsLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_claimedPaymentsKey);
      if (raw != null) _claimedPayments.addAll(raw);
    } catch (_) {}
  }

  Future<void> _persistClaimedPayments() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var ids = _claimedPayments.toList();
      if (ids.length > 500) {
        ids = ids.sublist(ids.length - 500);
        _claimedPayments
          ..clear()
          ..addAll(ids);
      }
      await prefs.setStringList(_claimedPaymentsKey, ids);
    } catch (_) {}
  }

  @visibleForTesting
  static bool mergeBrixPayment(List<dynamic> payments, Map<String, dynamic> incoming) {
    final hash = incoming['paymentHash']?.toString() ?? '';
    final index = hash.isEmpty
        ? -1
        : payments.indexWhere((p) => p is Map && p['paymentHash']?.toString() == hash);
    if (index == -1) {
      payments.add(incoming);
      return true;
    }

    final existing = Map<String, dynamic>.from(payments[index] as Map);
    final existingFee = (existing['feeSats'] as num?)?.toInt() ?? 0;
    final incomingFee = (incoming['feeSats'] as num?)?.toInt() ?? 0;
    final existingGross = (existing['grossAmountSats'] as num?)?.toInt() ?? 0;
    final incomingGross = (incoming['grossAmountSats'] as num?)?.toInt() ?? 0;
    if (existingFee > 0 && incomingFee > 0 &&
        (existingFee != incomingFee || existingGross != incomingGross)) {
      broLog('⚠️ [BRIX] Conflicting fee metadata ignored for hash ${hash.substring(0, hash.length > 8 ? 8 : hash.length)}');
      return false;
    }
    if (existingFee > 0 && incomingFee == 0) return false;

    // O evento Spark pode chegar antes do claim. Nesse caso, enriquecer o
    // mesmo registro com os valores autenticados do servidor, sem duplicá-lo.
    if (incomingFee > 0) {
      existing['feeSats'] = incomingFee;
      existing['grossAmountSats'] = incomingGross;
    }
    existing['isBrix'] = true;
    payments[index] = existing;
    return true;
  }

  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  static const _brixPaymentsKey = 'brix_received_payments';
  static bool _migrated = false;
  static Future<void> _brixStorageQueue = Future.value();

  @visibleForTesting
  static Future<T> serializeBrixStorage<T>(Future<T> Function() operation) {
    final result = _brixStorageQueue.then((_) => operation());
    _brixStorageQueue = result.then((_) {}, onError: (_, __) {});
    return result;
  }

  /// One-time migration from SharedPreferences to FlutterSecureStorage
  static Future<void> _migrateIfNeeded() async {
    if (_migrated) return;
    _migrated = true;
    try {
      final existing = await _secureStorage.read(key: _brixPaymentsKey);
      if (existing != null) return; // already migrated
      final prefs = await SharedPreferences.getInstance();
      final old = prefs.getString(_brixPaymentsKey);
      if (old != null && old != '[]') {
        await _secureStorage.write(key: _brixPaymentsKey, value: old);
        await prefs.remove(_brixPaymentsKey);
        broLog('🔒 [BRIX] Migrated payments to secure storage');
      }
    } catch (e) {
      broLog('⚠️ [BRIX] Migration error (non-fatal): $e');
    }
  }

  /// Persist a received BRIX payment locally so it appears in wallet history
  /// even if the Spark SDK doesn't return it in listPayments().
  static Future<void> persistBrixPayment({
    required int amountSats,
    required String description,
    String? paymentHash,
    DateTime? timestamp,
    int grossAmountSats = 0,
    int feeSats = 0,
  }) {
    return serializeBrixStorage(() async {
      try {
        await _migrateIfNeeded();
        final raw = await _secureStorage.read(key: _brixPaymentsKey) ?? '[]';
        final List<dynamic> list = json.decode(raw);
        final payment = <String, dynamic>{
          'amountSats': amountSats,
          'grossAmountSats': grossAmountSats > 0 ? grossAmountSats : amountSats + feeSats,
          'feeSats': feeSats,
          'description': description,
          'paymentHash': paymentHash,
          'createdAt': (timestamp ?? DateTime.now()).toIso8601String(),
          'type': 'received',
          'direction': 'incoming',
          'status': 'Complete',
          'isBrix': true,
        };
        final merged = mergeBrixPayment(list, payment);
        if (!merged) return;
        await _secureStorage.write(key: _brixPaymentsKey, value: json.encode(list));
        broLog('💾 [BRIX] Persisted local: $amountSats sats (fee=$feeSats), hash=${paymentHash?.substring(0, 8) ?? "N/A"}');
      } catch (e) {
        broLog('❌ [BRIX] Failed to persist: $e');
      }
    });
  }

  /// Load locally persisted BRIX payments for wallet screen fallback.
  static Future<List<Map<String, dynamic>>> getLocalBrixPayments() {
    return serializeBrixStorage(() async {
      try {
        await _migrateIfNeeded();
        final raw = await _secureStorage.read(key: _brixPaymentsKey) ?? '[]';
        final List<dynamic> list = json.decode(raw);
        return list.map((p) => Map<String, dynamic>.from(p)).toList();
      } catch (e) {
        broLog('❌ [BRIX] Failed to load local: $e');
        return <Map<String, dynamic>>[];
      }
    });
  }

  static const _pendingFeesKey = 'brix_pending_fee_payments';
  final Set<String> _feePaymentsInFlight = {};
  bool _processingFees = false;
  Future<void> _feeStorageLock = Future<void>.value();
  Future<SharedPreferences> Function() _feePrefs = SharedPreferences.getInstance;

  @visibleForTesting
  static int calculateBrixFee(int amountSats) {
    if (amountSats <= 1) return 0;
    final calculated = (amountSats * AppConfig.brixFeePercent).round();
    return calculated < 1 ? 1 : calculated;
  }

  @visibleForTesting
  static bool isSettledIncomingPayment(
    Map<String, dynamic> status, {
    required String paymentHash,
    required int amountSats,
  }) {
    return status['paid'] == true &&
        status['paymentHash'] == paymentHash &&
        status['direction'] == 'receive' &&
        status['amountSats'] == amountSats.toString();
  }

  @visibleForTesting
  static bool isSettledOutgoingFee(
    Map<String, dynamic> payResult, {
    required String paymentHash,
    required int feeSats,
  }) {
    final payment = payResult['payment'];
    return payResult['success'] == true &&
        payment is Map &&
        payment['status'] == 'PaymentStatus.completed' &&
        payment['paymentHash'] == paymentHash &&
        payment['amount']?.toString() == feeSats.toString();
  }

  @visibleForTesting
  static bool isDefinitivelyFailedOutgoingFee(Map<String, dynamic> payResult) {
    final payment = payResult['payment'];
    return (payResult['success'] == true &&
            payment is Map &&
            payment['status'] == 'PaymentStatus.failed') ||
        (payResult['success'] != true && payResult['mayStillSucceed'] != true);
  }

  @visibleForTesting
  static bool isSettledOutgoingFeeStatus(
    Map<String, dynamic> status, {
    required String paymentHash,
    required int feeSats,
  }) {
    return status['paid'] == true &&
        status['paymentHash'] == paymentHash &&
        status['direction'] == 'send' &&
        status['amountSats'] == feeSats.toString();
  }

  @visibleForTesting
  static bool isMissingOutgoingPayment(Map<String, dynamic> status) {
    final error = status['error']?.toString().toLowerCase() ?? '';
    return status['paid'] == false && error.contains('payment not found');
  }

  @visibleForTesting
  static bool isFailedOutgoingFeeStatus(
    Map<String, dynamic> status, {
    required String paymentHash,
    required int feeSats,
  }) {
    return status['status'] == 'failed' &&
        status['paymentHash'] == paymentHash &&
        status['direction'] == 'send' &&
        status['amountSats'] == feeSats.toString();
  }

  Future<T> _withFeeStorageLock<T>(Future<T> Function() action) {
    final previous = _feeStorageLock;
    final completer = Completer<void>();
    _feeStorageLock = completer.future;
    return previous.then((_) => action()).whenComplete(completer.complete);
  }

  @visibleForTesting
  void resetFeeStateForTest({
    Future<SharedPreferences> Function()? preferences,
  }) {
    _paidFees.clear();
    _paidFeesLoaded = false;
    _feePaymentsInFlight.clear();
    _processingFees = false;
    _feeStorageLock = Future<void>.value();
    _feePrefs = preferences ?? SharedPreferences.getInstance;
  }

  @visibleForTesting
  Future<T> runWithFeeStorageLock<T>(Future<T> Function() action) {
    return _withFeeStorageLock(action);
  }

  @visibleForTesting
  Future<void> queueBrixFeeForTest({
    required String requestId,
    required String? paymentHash,
    required String bolt11,
    required int amountSats,
    required int feeSats,
  }) {
    return _queueBrixFee(
      requestId: requestId,
      paymentHash: paymentHash,
      bolt11: bolt11,
      amountSats: amountSats,
      feeSats: feeSats,
    );
  }

  @visibleForTesting
  Future<Map<String, dynamic>?> updateBrixFeeForTest(
    String requestId,
    void Function(Map<String, dynamic> fee) update,
  ) {
    return _updateBrixFee(requestId, update);
  }

  @visibleForTesting
  Future<void> settleBrixFeeForTest(String requestId) {
    return _settleBrixFee(requestId);
  }

  @visibleForTesting
  Future<void> reconcileBrixFeeForTest(
    Map<String, dynamic> fee,
    Future<Map<String, dynamic>> Function(String paymentHash) checkStatus, {
    Future<void> Function(Map<String, dynamic> originalAttempt)? resumeSameAttempt,
  }) {
    return _reconcileBrixFee(
      fee,
      checkStatus,
      resumeSameAttempt: resumeSameAttempt,
    );
  }

  @visibleForTesting
  Future<void> sendBrixFeeForTest(
    Map<String, dynamic> fee, {
    required Future<Map<String, dynamic>> Function() getInvoice,
    required Future<Map<String, dynamic>?> Function(String bolt11) decodeInvoice,
    required Future<Map<String, dynamic>?> Function(
      String bolt11,
      String idempotencyKey,
    ) payInvoice,
    bool resumingMissingPayment = false,
  }) {
    return _sendBrixFee(
      fee,
      getInvoiceOverride: getInvoice,
      decodeInvoiceOverride: decodeInvoice,
      payInvoiceOverride: payInvoice,
      resumingMissingPayment: resumingMissingPayment,
    );
  }

  Future<void> _queueBrixFee({
    required String requestId,
    required String? paymentHash,
    required String bolt11,
    required int amountSats,
    required int feeSats,
  }) async {
    await _loadPaidFees();
    if (_paidFees.contains(requestId)) return;

    await _withFeeStorageLock(() async {
      final prefs = await _feePrefs();
      final pending = _loadPendingFees(prefs);
      if (pending.any((fee) => fee['requestId'] == requestId)) return;

      pending.add({
        'requestId': requestId,
        'paymentHash': paymentHash,
        'bolt11': bolt11,
        'amountSats': amountSats,
        'feeSats': feeSats,
        'state': paymentHash == null || paymentHash.isEmpty
            ? BrixFeeState.awaitingPaymentHash.name
            : BrixFeeState.awaitingReceipt.name,
        'idempotencyKey': const Uuid().v4(),
      });
      await _savePendingFees(prefs, pending);
    });
  }

  List<Map<String, dynamic>> _loadPendingFees(SharedPreferences prefs) {
    try {
      final decoded = jsonDecode(prefs.getString(_pendingFeesKey) ?? '[]');
      if (decoded is! List) throw const FormatException('Fee queue is not a list');
      final fees = decoded.whereType<Map>().map((fee) {
        return fee.map((key, value) => MapEntry(key.toString(), value));
      }).where((fee) {
        return fee['requestId'] is String &&
            fee['amountSats'] is int &&
            fee['feeSats'] is int &&
            (fee['paymentHash'] == null || fee['paymentHash'] is String) &&
            (fee['bolt11'] == null || fee['bolt11'] is String);
      }).toList();
      if (fees.length != decoded.length) {
        throw const FormatException('Fee queue contains an invalid entry');
      }
      return fees;
    } catch (e) {
      // Never overwrite unreadable financial state with an empty queue.
      broLog('⚠️ [BRIX-RELAY] Invalid pending fee storage; processing stopped: $e');
      throw StateError('Could not read BRIX fee queue');
    }
  }

  Future<void> _savePendingFees(
    SharedPreferences prefs,
    List<Map<String, dynamic>> pending,
  ) async {
    final saved = await prefs.setString(_pendingFeesKey, jsonEncode(pending));
    if (!saved) throw StateError('Could not persist BRIX fee queue');
  }

  Future<void> _processBrixFees() async {
    if (_processingFees || _context == null) return;
    _processingFees = true;
    try {
      await _loadPaidFees();
      final prefs = await _feePrefs();
      final pending = _loadPendingFees(prefs);
      if (pending.isEmpty) return;

      final breezProvider = _context!.read<BreezProvider>();
      for (final storedFee in List<Map<String, dynamic>>.of(pending)) {
        final requestId = storedFee['requestId'] as String;
        if (_paidFees.contains(requestId) || _feePaymentsInFlight.contains(requestId)) {
          continue;
        }

        var fee = storedFee;
        final state = BrixFeeState.fromStorage(fee['state']);
        if (state == BrixFeeState.pendingSettlement ||
            (state == BrixFeeState.sending && fee['feePaymentHash'] is String)) {
          // Após crash/timeout, primeiro reconciliar a tentativa original.
          // Se o SDK não tem registro, retomar com a MESMA invoice e key.
          await _reconcileBrixFee(
            fee,
            breezProvider.checkPaymentStatus,
            resumeSameAttempt: (originalAttempt) =>
                _sendBrixFee(originalAttempt, resumingMissingPayment: true),
          );
          continue;
        }
        if (state == BrixFeeState.sending) {
          await _sendBrixFee(fee);
          continue;
        }
        if (state != BrixFeeState.awaitingReceipt &&
            state != BrixFeeState.awaitingPaymentHash) {
          continue;
        }

        var paymentHash = fee['paymentHash'] as String?;
        if (paymentHash == null || paymentHash.isEmpty) {
          final bolt11 = fee['bolt11'] as String?;
          if (bolt11 == null || bolt11.isEmpty) continue;
          final decoded = await breezProvider.decodeInvoice(bolt11);
          paymentHash = decoded?['invoice']?['paymentHash'] as String?;
          if (paymentHash == null || paymentHash.isEmpty) continue;
          final updated = await _updateBrixFee(requestId, (item) {
            item['paymentHash'] = paymentHash;
            item['state'] = BrixFeeState.awaitingReceipt.name;
          });
          if (updated == null) continue;
          fee = updated;
        }

        final amountSats = fee['amountSats'] as int;
        final status = await breezProvider.checkPaymentStatus(paymentHash);
        if (!isSettledIncomingPayment(
          status,
          paymentHash: paymentHash,
          amountSats: amountSats,
        )) {
          continue;
        }

        await _sendBrixFee(fee);
      }
    } catch (e) {
      broLog('⚠️ [BRIX-RELAY] Fee settlement check failed; will retry: $e');
    } finally {
      _processingFees = false;
    }
  }

  Future<Map<String, dynamic>?> _updateBrixFee(
    String requestId,
    void Function(Map<String, dynamic> fee) update,
  ) {
    return _withFeeStorageLock(() async {
      final prefs = await _feePrefs();
      final pending = _loadPendingFees(prefs);
      final index = pending.indexWhere((fee) => fee['requestId'] == requestId);
      if (index < 0) return null;
      update(pending[index]);
      await _savePendingFees(prefs, pending);
      return pending[index];
    });
  }

  Future<void> _reconcileBrixFee(
    Map<String, dynamic> fee,
    Future<Map<String, dynamic>> Function(String paymentHash) checkStatus, {
    Future<void> Function(Map<String, dynamic> originalAttempt)? resumeSameAttempt,
  }) async {
    final requestId = fee['requestId'] as String;
    final feePaymentHash = fee['feePaymentHash'] as String?;
    if (feePaymentHash == null || feePaymentHash.isEmpty) {
      // Legacy ambiguous entries must never trigger a blind second payment.
      broLog('⚠️ [BRIX-RELAY] Pending fee has no outgoing hash; manual reconciliation required');
      return;
    }

    final status = await checkStatus(feePaymentHash);
    if (isSettledOutgoingFeeStatus(
      status,
      paymentHash: feePaymentHash,
      feeSats: fee['feeSats'] as int,
    )) {
      await _settleBrixFee(
        requestId,
        paymentHash: feePaymentHash,
        incomingPaymentHash: fee['paymentHash'] as String?,
        feeSats: fee['feeSats'] as int,
      );
      return;
    }
    if (isMissingOutgoingPayment(status)) {
      if (resumeSameAttempt != null &&
          fee['feeInvoice'] is String &&
          fee['idempotencyKey'] is String) {
        await resumeSameAttempt(fee);
      }
      return;
    }
    if (isFailedOutgoingFeeStatus(
      status,
      paymentHash: feePaymentHash,
      feeSats: fee['feeSats'] as int,
    )) {
      await _updateBrixFee(requestId, (item) {
        item['state'] = BrixFeeState.awaitingReceipt.name;
        item.remove('feePaymentHash');
        item.remove('feeInvoice');
        item['idempotencyKey'] = const Uuid().v4();
      });
    }
  }

  Future<void> _settleBrixFee(
    String requestId, {
    String? paymentHash,
    String? incomingPaymentHash,
    int? feeSats,
  }) async {
    await _withFeeStorageLock(() async {
      final prefs = await _feePrefs();
      if (paymentHash != null && paymentHash.isNotEmpty) {
        if (incomingPaymentHash != null &&
            incomingPaymentHash.isNotEmpty &&
            feeSats != null) {
          final links = await getSettledFeeLinks();
          links[incomingPaymentHash] = {
            'feePaymentHash': paymentHash,
            'feeSats': feeSats,
          };
          final saved = await prefs.setString(
              _settledFeeLinksKey, jsonEncode(links));
          if (!saved) throw StateError('Could not persist BRIX fee link');
        }
        final hashes = prefs.getStringList(_settledFeeHashesKey) ?? <String>[];
        if (!hashes.contains(paymentHash)) {
          hashes.add(paymentHash);
          final saved = await prefs.setStringList(_settledFeeHashesKey, hashes);
          if (!saved) throw StateError('Could not persist BRIX fee display hash');
        }
      }
      final wasPaid = _paidFees.contains(requestId);
      _paidFees.add(requestId);
      try {
        await _persistPaidFees();
      } catch (_) {
        if (!wasPaid) _paidFees.remove(requestId);
        rethrow;
      }
      final pending = _loadPendingFees(prefs);
      pending.removeWhere((fee) => fee['requestId'] == requestId);
      await _savePendingFees(prefs, pending);
    });
  }

  /// Send the fee only after the exact incoming payment has settled.
  Future<void> _sendBrixFee(
    Map<String, dynamic> fee, {
    Future<Map<String, dynamic>> Function()? getInvoiceOverride,
    Future<Map<String, dynamic>?> Function(String bolt11)? decodeInvoiceOverride,
    Future<Map<String, dynamic>?> Function(
      String bolt11,
      String idempotencyKey,
    )? payInvoiceOverride,
    bool resumingMissingPayment = false,
  }) async {
    final requestId = fee['requestId'] as String;
    final feeSats = fee['feeSats'] as int;
    if (_paidFees.contains(requestId) || !_feePaymentsInFlight.add(requestId)) return;

    try {
      if (payInvoiceOverride == null &&
          (!AppConfig.isPlatformLightningAddressValid || _context == null)) {
        return;
      }

      final prepared = await _updateBrixFee(requestId, (item) {
        final savedKey = item['idempotencyKey'] as String?;
        if (savedKey == null || savedKey.isEmpty) {
          item['idempotencyKey'] = const Uuid().v4();
        }
        item['state'] = BrixFeeState.sending.name;
      });
      if (prepared == null) return;
      final idempotencyKey = prepared['idempotencyKey'] as String;

      var feeInvoice = fee['feeInvoice'] as String?;
      if (feeInvoice == null || feeInvoice.isEmpty) {
        final result = getInvoiceOverride != null
            ? await getInvoiceOverride()
            : await LnAddressService().getInvoice(
                lnAddress: AppConfig.platformLightningAddress,
                amountSats: feeSats,
                comment: 'BRIX fee',
              );
        if (result['success'] != true || result['invoice'] == null) {
          await _updateBrixFee(requestId, (item) {
            item['state'] = BrixFeeState.awaitingReceipt.name;
          });
          return;
        }
        feeInvoice = result['invoice'] as String;
      }

      final decoded = decodeInvoiceOverride != null
          ? await decodeInvoiceOverride(feeInvoice)
          : await _context!.read<BreezProvider>().decodeInvoice(feeInvoice);
      final feePaymentHash = decoded?['invoice']?['paymentHash'] as String?;
      final decodedAmount = int.tryParse(
          decoded?['invoice']?['amountSats']?.toString() ?? '');
      if (decoded?['success'] != true ||
          feePaymentHash == null ||
          feePaymentHash.isEmpty ||
          decodedAmount != feeSats) {
        // Uma tentativa persistida nunca volta ao fluxo comum por falha de
        // decode: sua identidade precisa continuar protegida contra duplicidade.
        await _updateBrixFee(requestId, (item) {
          item['state'] = item['feePaymentHash'] is String
              ? BrixFeeState.pendingSettlement.name
              : BrixFeeState.awaitingReceipt.name;
        });
        return;
      }
      final previousHash = fee['feePaymentHash'] as String?;
      if (previousHash != null &&
          previousHash.isNotEmpty &&
          previousHash != feePaymentHash) {
        await _updateBrixFee(requestId, (item) {
          item['state'] = BrixFeeState.pendingSettlement.name;
        });
        return;
      }
      await _updateBrixFee(requestId, (item) {
        item['feeInvoice'] = feeInvoice;
        item['feePaymentHash'] = feePaymentHash;
        item['state'] = BrixFeeState.sending.name;
      });

      Map<String, dynamic>? payResult;
      Object? paymentError;
      try {
        payResult = payInvoiceOverride != null
            ? await payInvoiceOverride(feeInvoice, idempotencyKey)
            : await _context!.read<BreezProvider>().payInvoice(
                feeInvoice,
                idempotencyKey: idempotencyKey,
              );
      } catch (e) {
        paymentError = e;
      }

      if (paymentError == null) {
        final settled = isSettledOutgoingFee(
          payResult!,
          paymentHash: feePaymentHash,
          feeSats: feeSats,
        );
        if (settled) {
          await _settleBrixFee(
            requestId,
            paymentHash: feePaymentHash,
            incomingPaymentHash: fee['paymentHash'] as String?,
            feeSats: feeSats,
          );
          broLog('⚡ [BRIX-RELAY] Fee settled: $feeSats sats');
          return;
        }

        final originalPayment = payResult['payment'];
        final protectedAttempt = resumingMissingPayment ||
            (fee['feePaymentHash'] is String && fee['feeInvoice'] is String);
        final originalFailed = protectedAttempt &&
            originalPayment is Map &&
            originalPayment['status'] == 'PaymentStatus.failed' &&
            originalPayment['paymentHash'] == feePaymentHash &&
            originalPayment['amount']?.toString() == feeSats.toString();
        if (originalFailed ||
            (!protectedAttempt && isDefinitivelyFailedOutgoingFee(payResult))) {
          await _updateBrixFee(requestId, (item) {
            item['state'] = BrixFeeState.awaitingReceipt.name;
            item.remove('feePaymentHash');
            item.remove('feeInvoice');
            item['idempotencyKey'] = const Uuid().v4();
          });
          return;
        }
      }

      await _updateBrixFee(requestId, (item) {
        item['state'] = BrixFeeState.pendingSettlement.name;
      });
      broLog('⏳ [BRIX-RELAY] Fee pending settlement; will reconcile before any retry${paymentError == null ? '' : ': $paymentError'}');
    } catch (e) {
      // Once an outgoing hash exists, the attempt may have reached the SDK.
      // Keep it pending instead of risking a blind second payment.
      try {
        await _updateBrixFee(requestId, (item) {
          item['state'] = item['feePaymentHash'] is String
              ? BrixFeeState.pendingSettlement.name
              : BrixFeeState.awaitingReceipt.name;
        });
      } catch (storageError) {
        broLog('⚠️ [BRIX-RELAY] Could not persist fee recovery state: $storageError');
      }
      broLog('⚠️ [BRIX-RELAY] Fee payment error; will reconcile: $e');
    } finally {
      _feePaymentsInFlight.remove(requestId);
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // OUTGOING PAYMENT QUEUE — Retry when recipients come online
  // ═══════════════════════════════════════════════════════════════════

  static const _pendingOutgoingKey = 'brix_pending_outgoing';
  static const _retryIntervalSeconds = 30;
  static const _maxAgeHours = 24;
  DateTime? _lastRetryCheck;
  bool _retrying = false;

  /// Queue an outgoing BRIX payment for retry when recipient comes online.
  /// Called when payInvoice fails (offline recipient or Spark incompatibility).
  Future<void> queueOutgoingPayment({
    required String recipient,
    required int amountSats,
    String? originalDest,
    String? comment,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final list = _loadQueue(prefs);

    // Prevent duplicate entries for same recipient+amount
    final exists = list.any((p) =>
        p['recipient'] == recipient &&
        p['amountSats'] == amountSats &&
        p['status'] == 'pending');
    if (exists) {
      broLog('⏳ [BRIX-QUEUE] Already queued: $amountSats sats → $recipient');
      return;
    }

    list.add({
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'recipient': recipient,
      'originalDest': originalDest ?? recipient,
      'amountSats': amountSats,
      'comment': comment,
      'createdAt': DateTime.now().toIso8601String(),
      'retryCount': 0,
      'lastRetry': null,
      'status': 'pending',
    });

    await _saveQueue(prefs, list);
    broLog('⏳ [BRIX-QUEUE] Queued: $amountSats sats → $recipient');
  }

  /// Get list of pending and expired outgoing payments (for UI display).
  Future<List<Map<String, dynamic>>> getPendingOutgoing() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadQueue(prefs)
        .where((p) => p['status'] == 'pending' || p['status'] == 'expired')
        .toList();
  }

  /// Cancel a queued outgoing payment by id.
  Future<void> cancelOutgoingPayment(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final list = _loadQueue(prefs);
    list.removeWhere((p) => p['id'] == id);
    await _saveQueue(prefs, list);
    broLog('🗑️ [BRIX-QUEUE] Cancelled: $id');
  }

  /// Called from _poll(). Retries pending outgoing BRIX payments.
  Future<void> _retryOutgoingPayments() async {
    if (_retrying || _context == null) return;

    // Rate limit retries
    final now = DateTime.now();
    if (_lastRetryCheck != null &&
        now.difference(_lastRetryCheck!).inSeconds < _retryIntervalSeconds) {
      return;
    }
    _lastRetryCheck = now;

    final prefs = await SharedPreferences.getInstance();
    final list = _loadQueue(prefs);
    if (list.isEmpty) return;

    _retrying = true;
    bool changed = false;

    try {
      final breezProvider = _context!.read<BreezProvider>();
      final lnService = LnAddressService();

      for (final payment in List.of(list)) {
        if (payment['status'] != 'pending') continue;

        // Expire old payments
        final created = DateTime.tryParse(payment['createdAt'] ?? '');
        if (created != null && now.difference(created).inHours > _maxAgeHours) {
          payment['status'] = 'expired';
          changed = true;
          broLog('⏰ [BRIX-QUEUE] Expired: ${payment['recipient']}');
          continue;
        }

        // Rate limit individual payment retries (30s minimum)
        final lastRetry = DateTime.tryParse(payment['lastRetry'] ?? '');
        if (lastRetry != null &&
            now.difference(lastRetry).inSeconds < _retryIntervalSeconds) {
          continue;
        }

        final recipient = payment['recipient'] as String;
        final amountSats = payment['amountSats'] as int;
        final paymentComment = payment['comment'] as String?;

        // v635 [BRIX-QUEUE] ANTI DOUBLE-SPEND: before generating a fresh
        // invoice and paying AGAIN, verify no previous attempt actually settled
        // on the Lightning network. A prior payInvoice may have returned
        // TIMEOUT_PENDING (or the app was killed mid-send) while the HTLC in
        // fact completed — retrying with a new invoice would pay the recipient
        // twice. We persist every attempted invoice's paymentHash and re-check
        // each one here before paying again.
        final priorHashes =
            (payment['attemptHashes'] as List?)?.cast<String>() ?? const <String>[];
        if (priorHashes.isNotEmpty) {
          final settled = await firstSettledHash(
            priorHashes,
            (h) async =>
                (await breezProvider.checkPaymentStatus(h))['paid'] == true,
          );
          if (settled != null) {
            payment['status'] = 'completed';
            changed = true;
            broLog('✅ [BRIX-QUEUE] Already settled by a prior attempt — NOT paying again: $amountSats sats → $recipient');
            onQueuedPaymentCompleted?.call(recipient, amountSats);
            continue;
          }
        }

        broLog('🔄 [BRIX-QUEUE] Retrying: $amountSats sats → $recipient (attempt ${payment['retryCount'] + 1})');
        payment['lastRetry'] = now.toIso8601String();
        payment['retryCount'] = (payment['retryCount'] as int) + 1;
        changed = true;

        try {
          // Try LNURL flow again
          final invoiceResult = await lnService.getInvoice(
            lnAddress: recipient,
            amountSats: amountSats,
            comment: paymentComment,
            senderPubkey: _pubkey,
          );

          if (invoiceResult['success'] != true) {
            // Still offline or errored — keep queued
            broLog('⏳ [BRIX-QUEUE] Still offline: $recipient');
            continue;
          }

          final invoice = invoiceResult['invoice'] as String;

          // v635: record THIS invoice's paymentHash BEFORE paying and persist
          // immediately, so a timeout/crash mid-send is still detectable by the
          // settlement re-check above on the next cycle (crash safety).
          try {
            final decoded = await breezProvider.decodeInvoice(invoice);
            final h = (decoded?['success'] == true)
                ? (decoded?['invoice']?['paymentHash'] as String?)
                : null;
            if (h != null && h.isNotEmpty) {
              final hashes =
                  (payment['attemptHashes'] as List?)?.cast<String>().toList() ??
                      <String>[];
              if (!hashes.contains(h)) hashes.add(h);
              // Bound growth (retries are rate-limited + age-capped anyway).
              while (hashes.length > 10) {
                hashes.removeAt(0);
              }
              payment['attemptHashes'] = hashes;
              await _saveQueue(prefs, list);
            }
          } catch (e) {
            broLog('⚠️ [BRIX-QUEUE] Could not decode invoice hash (will still guard via re-check): $e');
          }

          // Try to pay
          final payResult = await breezProvider.payInvoice(invoice);

          if (payResult != null && payResult['success'] == true) {
            payment['status'] = 'completed';
            changed = true;
            broLog('✅ [BRIX-QUEUE] Payment completed: $amountSats sats → $recipient');
            // Notify listeners
            onQueuedPaymentCompleted?.call(recipient, amountSats);
          } else {
            // Payment failed OR timed out (may still settle). Keep queued; the
            // settlement re-check at the top of the next cycle prevents a
            // double-pay if a TIMEOUT_PENDING attempt actually completed.
            final et = payResult?['errorType'];
            broLog('⏳ [BRIX-QUEUE] Pay not confirmed (errorType=$et), keeping queued: $recipient');
          }
        } catch (e) {
          broLog('⚠️ [BRIX-QUEUE] Retry error: $e');
        }
      }

      if (changed) {
        // Remove only completed entries; keep expired for user visibility
        list.removeWhere((p) => p['status'] == 'completed');
        await _saveQueue(prefs, list);
      }
    } catch (e) {
      broLog('⚠️ [BRIX-QUEUE] Retry cycle error: $e');
    } finally {
      _retrying = false;
    }
  }

  List<Map<String, dynamic>> _loadQueue(SharedPreferences prefs) {
    final raw = prefs.getString(_pendingOutgoingKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveQueue(SharedPreferences prefs, List<Map<String, dynamic>> list) async {
    await prefs.setString(_pendingOutgoingKey, jsonEncode(list));
  }
}

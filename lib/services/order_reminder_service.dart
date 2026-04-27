import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:bro_app/services/notification_service.dart';

/// Envia lembretes progressivos quando uma ordem esta proxima do prazo de 36h.
///
/// Cenario A (status=accepted): provedor aceitou mas nao subiu comprovante.
///   Anchor: acceptedAt — remind the PROVIDER.
/// Cenario B (status=awaiting_confirmation): comprovante enviado mas usuario
///   nao confirmou. Anchor: receipt_submitted_at — remind the USER.
///
/// Milestones: 24h, 30h e 35h (1h antes do deadline).
/// Cada lembrete eh disparado apenas UMA vez por ordem/milestone/cenario via
/// persistencia em SharedPreferences.
class OrderReminderService {
  static final OrderReminderService _instance = OrderReminderService._internal();
  factory OrderReminderService() => _instance;
  OrderReminderService._internal();

  static const String _sentKey = 'bro_reminders_sent';
  static const Duration _deadline = Duration(hours: 36);
  // Milestones em horas (em ordem crescente). A ultima eh 1h antes do deadline.
  static const List<int> _milestonesH = [24, 30, 35];

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initDone = false;

  Future<void> _ensureInit() async {
    if (_initDone) return;
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
    );
    _initDone = true;
  }

  /// Checa todas as ordens e dispara lembretes pendentes.
  /// [orders] eh uma lista de mapas serializados (mesmo formato do storage).
  /// [currentPubkey] eh a pubkey do usuario atual (para filtrar papel).
  Future<int> checkAndNotify({
    required List<Map<String, dynamic>> orders,
    required String currentPubkey,
  }) async {
    if (currentPubkey.isEmpty) return 0;
    final prefs = await SharedPreferences.getInstance();
    final sentJson = prefs.getString(_sentKey) ?? '[]';
    final sent = Set<String>.from(jsonDecode(sentJson) as List);

    final now = DateTime.now();
    int shown = 0;

    for (final order in orders) {
      final reminders = _computeDueReminders(
        order: order,
        currentPubkey: currentPubkey,
        now: now,
        alreadySent: sent,
      );
      for (final r in reminders) {
        final ok = await _showReminder(r);
        if (ok) {
          sent.add(r.key);
          shown++;
        }
      }
    }

    if (shown > 0) {
      // Trim: mantem ultimos 500 para evitar crescimento indefinido
      final list = sent.toList();
      if (list.length > 500) list.removeRange(0, list.length - 500);
      await prefs.setString(_sentKey, jsonEncode(list));
      broLog('⏰ [Reminder] $shown lembrete(s) enviado(s)');
    }
    return shown;
  }

  List<_Reminder> _computeDueReminders({
    required Map<String, dynamic> order,
    required String currentPubkey,
    required DateTime now,
    required Set<String> alreadySent,
  }) {
    final result = <_Reminder>[];
    final orderId = order['id']?.toString() ?? '';
    if (orderId.isEmpty) return result;

    final status = order['status']?.toString() ?? '';
    final metadata = (order['metadata'] as Map?)?.cast<String, dynamic>() ?? {};

    // Pula ordens ja auto-liquidadas
    if (metadata['autoLiquidated'] == true) return result;

    final providerId = (order['providerId'] as String?) ??
        (metadata['providerId'] as String?) ??
        (metadata['provider_id'] as String?) ??
        '';
    final userPubkey = order['userPubkey'] as String? ?? '';

    String? scenario;
    String? anchorIso;
    String? targetRole; // 'provider' | 'user'

    if (status == 'accepted') {
      // Cenario A: provedor precisa pagar+subir comprovante
      anchorIso = (order['acceptedAt'] as String?) ??
          (metadata['acceptedAt'] as String?) ??
          (metadata['accepted_at'] as String?);
      scenario = 'A';
      targetRole = 'provider';
      if (providerId != currentPubkey) return result; // so notifica o provedor
    } else if (status == 'awaiting_confirmation') {
      // Cenario B: usuario precisa confirmar
      anchorIso = (metadata['receipt_submitted_at'] as String?) ??
          (metadata['proofReceivedAt'] as String?) ??
          (metadata['proofSentAt'] as String?);
      scenario = 'B';
      targetRole = 'user';
      if (userPubkey != currentPubkey) return result; // so notifica o criador
    } else {
      return result;
    }

    if (anchorIso == null || anchorIso.isEmpty) return result;

    DateTime anchor;
    try {
      anchor = DateTime.parse(anchorIso);
    } catch (_) {
      return result;
    }

    final elapsed = now.difference(anchor);
    // Se ja passou do deadline, nao mandamos lembrete (auto-liquidacao assume)
    if (elapsed >= _deadline) return result;

    for (final h in _milestonesH) {
      if (elapsed.inHours < h) continue; // ainda nao chegou nesse milestone
      final key = '$orderId:$scenario:${h}h';
      if (alreadySent.contains(key)) continue;
      result.add(_Reminder(
        key: key,
        orderId: orderId,
        scenario: scenario,
        milestoneH: h,
        targetRole: targetRole!,
      ));
    }
    return result;
  }

  Future<bool> _showReminder(_Reminder r) async {
    try {
      await _ensureInit();
      final shortId = r.orderId.length >= 8
          ? r.orderId.substring(0, 8)
          : r.orderId;
      final hoursLeft = 36 - r.milestoneH;
      final title = _buildTitle(r);
      final body = _buildBody(r, shortId, hoursLeft);
      final payload = 'reminder:${r.scenario}:${r.milestoneH}h:${r.orderId}';

      // Reusa o dedup global do NotificationService para que os papeis
      // (foreground/background) nao dupliquem a mesma notificacao.
      await NotificationService().showGeneric(
        title: title,
        body: body,
        dedupKey: payload,
      );
      broLog('⏰ [Reminder] $title — $body');
      return true;
    } catch (e) {
      broLog('❌ [Reminder] erro ao mostrar: $e');
      return false;
    }
  }

  String _buildTitle(_Reminder r) {
    if (r.milestoneH == 35) return '🚨 Prazo final em 1h!';
    if (r.milestoneH == 30) return '⏳ Faltam 6h para o prazo';
    return '⏰ Faltam 12h para o prazo';
  }

  String _buildBody(_Reminder r, String shortId, int hoursLeft) {
    // Cenario A: provedor — pague a conta e envie o comprovante
    if (r.scenario == 'A') {
      if (r.milestoneH == 35) {
        return 'Pague a conta e envie o comprovante na ordem $shortId em 1h para evitar cancelamento e perda da garantia.';
      }
      return 'Pague a conta e envie o comprovante da ordem $shortId. Faltam ${hoursLeft}h.';
    }
    // Cenario B: usuario — confirme o pagamento
    if (r.milestoneH == 35) {
      return 'Confirme o comprovante da ordem $shortId em 1h ou ela sera auto-liquidada a favor do Bro.';
    }
    return 'Confirme o comprovante da ordem $shortId. Faltam ${hoursLeft}h.';
  }
}

class _Reminder {
  final String key;
  final String orderId;
  final String scenario;
  final int milestoneH;
  final String targetRole;

  _Reminder({
    required this.key,
    required this.orderId,
    required this.scenario,
    required this.milestoneH,
    required this.targetRole,
  });
}

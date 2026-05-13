import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Notificação salva no "inbox" do app (aba de Notificações).
///
/// Persistida em SharedPreferences sob `notifications_inbox` como JSON array.
/// Cap: últimas 100 entradas (FIFO).
class NotificationItem {
  final String id;
  final String title;
  final String body;
  final DateTime timestamp;
  final String type; // ex: order_accepted, order_completed, payment_received, brix
  final String? orderId;
  final String? payload;
  bool read;

  NotificationItem({
    required this.id,
    required this.title,
    required this.body,
    required this.timestamp,
    this.type = 'generic',
    this.orderId,
    this.payload,
    this.read = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'timestamp': timestamp.toIso8601String(),
        'type': type,
        'orderId': orderId,
        'payload': payload,
        'read': read,
      };

  factory NotificationItem.fromJson(Map<String, dynamic> j) => NotificationItem(
        id: j['id']?.toString() ?? '',
        title: j['title']?.toString() ?? '',
        body: j['body']?.toString() ?? '',
        timestamp: DateTime.tryParse(j['timestamp']?.toString() ?? '') ?? DateTime.now(),
        type: j['type']?.toString() ?? 'generic',
        orderId: j['orderId']?.toString(),
        payload: j['payload']?.toString(),
        read: j['read'] == true,
      );
}

class NotificationInbox {
  static const _key = 'notifications_inbox';
  static const _maxItems = 100;

  /// Salva uma notificação no inbox. Dedup por `id` (sobrescreve se já existir).
  static Future<void> add(NotificationItem item) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await _read(prefs);
      // Remove duplicado pelo mesmo id (se existir)
      list.removeWhere((e) => e.id == item.id);
      list.insert(0, item);
      if (list.length > _maxItems) {
        list.removeRange(_maxItems, list.length);
      }
      await prefs.setString(_key, jsonEncode(list.map((e) => e.toJson()).toList()));
    } catch (_) {/* silent */}
  }

  /// Adiciona uma notificação a partir de title/body/payload (forma curta usada
  /// pelos serviços de notificação).
  static Future<void> addRaw({
    required String title,
    required String body,
    String? payload,
  }) async {
    String type = 'generic';
    String? orderId;
    if (payload != null && payload.contains(':')) {
      final parts = payload.split(':');
      type = parts.first;
      if (parts.length > 1) orderId = parts.sublist(1).join(':');
    }
    await add(NotificationItem(
      id: payload != null && payload.isNotEmpty
          ? payload
          : '${DateTime.now().millisecondsSinceEpoch}_$title',
      title: title,
      body: body,
      timestamp: DateTime.now(),
      type: type,
      orderId: orderId,
      payload: payload,
    ));
  }

  static Future<List<NotificationItem>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    return _read(prefs);
  }

  static Future<int> unreadCount() async {
    final all = await getAll();
    return all.where((n) => !n.read).length;
  }

  static Future<void> markAllRead() async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _read(prefs);
    for (final n in list) {
      n.read = true;
    }
    await prefs.setString(_key, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  static Future<void> markRead(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _read(prefs);
    for (final n in list) {
      if (n.id == id) n.read = true;
    }
    await prefs.setString(_key, jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Future<List<NotificationItem>> _read(SharedPreferences prefs) async {
    try {
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return [];
      final arr = jsonDecode(raw) as List<dynamic>;
      return arr
          .whereType<Map<String, dynamic>>()
          .map(NotificationItem.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }
}

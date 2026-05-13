import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/notification_item.dart';
import '../models/order.dart';
import '../providers/order_provider.dart';
import 'provider_order_detail_screen.dart';
import 'user_order_detail_screen.dart';

/// Tela "Inbox" de notificações persistidas.
class NotificationsInboxScreen extends StatefulWidget {
  const NotificationsInboxScreen({Key? key}) : super(key: key);

  @override
  State<NotificationsInboxScreen> createState() => _NotificationsInboxScreenState();
}

class _NotificationsInboxScreenState extends State<NotificationsInboxScreen> {
  List<NotificationItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await NotificationInbox.getAll();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
    // Marca todas como lidas ao abrir (UX comum em apps de mensageria)
    if (items.any((n) => !n.read)) {
      await NotificationInbox.markAllRead();
    }
  }

  Future<void> _clearAll() async {
    await NotificationInbox.clear();
    if (!mounted) return;
    setState(() => _items = []);
    final l = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l.t('notifications_cleared')),
        backgroundColor: const Color(0xFFFF9800),
      ),
    );
  }

  String _formatRelative(BuildContext context, DateTime ts) {
    final l = AppLocalizations.of(context);
    final diff = DateTime.now().difference(ts);
    if (diff.inMinutes < 1) return l.t('notifications_just_now');
    if (diff.inMinutes < 60) return l.tp('notifications_minutes_ago', {'n': '${diff.inMinutes}'});
    if (diff.inHours < 24) return l.tp('notifications_hours_ago', {'n': '${diff.inHours}'});
    return l.tp('notifications_days_ago', {'n': '${diff.inDays}'});
  }

  void _openOrder(NotificationItem n) {
    final orderId = n.orderId;
    if (orderId == null || orderId.isEmpty) return;
    final orderProvider = context.read<OrderProvider>();
    final currentPubkey = orderProvider.currentUserPubkey;
    Order? order;
    try {
      order = orderProvider.orders.firstWhere((o) => o.id == orderId);
    } catch (_) {
      // tenta prefix-match
      try {
        order = orderProvider.orders.firstWhere(
            (o) => o.id.startsWith(orderId) || orderId.startsWith(o.id.substring(0, 8)));
      } catch (_) {}
    }
    if (order == null) {
      // Sem ordem local, navega via rota /order-status que aceita orderId.
      Navigator.pushNamed(context, '/order-status',
          arguments: {'orderId': orderId});
      return;
    }
    final isProvider =
        order.providerId == currentPubkey && order.userPubkey != currentPubkey;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => isProvider
            ? ProviderOrderDetailScreen(
                orderId: order!.id,
                providerId: currentPubkey ?? '',
              )
            : UserOrderDetailScreen(orderId: order!.id),
      ),
    );
  }

  IconData _iconFor(String type) {
    switch (type) {
      case 'order_accepted':
        return Icons.handshake;
      case 'order_completed':
      case 'liquidated':
        return Icons.check_circle;
      case 'order_disputed':
        return Icons.gavel;
      case 'payment_received':
      case 'brix':
        return Icons.flash_on;
      case 'invoice_payment_due':
        return Icons.payment;
      default:
        return Icons.notifications_active;
    }
  }

  Color _colorFor(String type) {
    switch (type) {
      case 'order_completed':
      case 'liquidated':
      case 'payment_received':
      case 'brix':
        return Colors.green;
      case 'order_disputed':
        return Colors.redAccent;
      case 'invoice_payment_due':
        return Colors.amber;
      default:
        return Colors.orange;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(l.t('notifications_title')),
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: l.t('notifications_clear_all'),
              onPressed: _clearAll,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.orange))
          : _items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.notifications_off,
                            color: Colors.white.withOpacity(0.3), size: 64),
                        const SizedBox(height: 16),
                        Text(
                          l.t('notifications_empty'),
                          style: const TextStyle(color: Colors.white70, fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l.t('notifications_empty_hint'),
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.4), fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  color: Colors.orange,
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final n = _items[i];
                      final color = _colorFor(n.type);
                      return GestureDetector(
                        onTap: () => _openOrder(n),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1A1A1A),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: n.read
                                  ? const Color(0xFF333333)
                                  : color.withOpacity(0.4),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: color.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                child: Icon(_iconFor(n.type), color: color, size: 18),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            n.title,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w600,
                                              fontSize: 14,
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        Text(
                                          _formatRelative(context, n.timestamp),
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(0.45),
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      n.body,
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.75),
                                        fontSize: 13,
                                      ),
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              if (n.orderId != null && n.orderId!.isNotEmpty)
                                Icon(Icons.chevron_right,
                                    color: Colors.white.withOpacity(0.3), size: 18),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

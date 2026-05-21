// Registry of supported payment methods.
//
// Each method has a stable `id` that is stored in `order.billType` and used
// throughout the app + backend. Adding a new country = appending to `kAll`.
//
// Today only `pix` and `boleto` have real parsers (in PaymentScreen +
// backend /pix/decode and /boleto/validate). The others are registered so
// providers can already opt-in via the filter; parsers for them will be
// added incrementally.

import 'package:flutter/material.dart';

class PaymentMethod {
  final String id;        // stored in order.billType
  final String country;   // ISO-2
  final String flag;      // emoji
  final String name;      // display name
  final String currency;  // ISO-4217
  final IconData icon;
  final bool active;      // false = visible in registry but no parser yet

  const PaymentMethod({
    required this.id,
    required this.country,
    required this.flag,
    required this.name,
    required this.currency,
    required this.icon,
    this.active = true,
  });
}

class PaymentMethods {
  static const List<PaymentMethod> kAll = [
    PaymentMethod(id: 'pix',          country: 'BR', flag: '🇧🇷', name: 'Pix',        currency: 'BRL', icon: Icons.pix,             active: true),
    PaymentMethod(id: 'boleto',       country: 'BR', flag: '🇧🇷', name: 'Boleto',     currency: 'BRL', icon: Icons.receipt_long,    active: true),
    PaymentMethod(id: 'electricity',  country: 'BR', flag: '🇧🇷', name: 'Luz',        currency: 'BRL', icon: Icons.bolt,            active: true),
    PaymentMethod(id: 'water',        country: 'BR', flag: '🇧🇷', name: 'Água',       currency: 'BRL', icon: Icons.water_drop,      active: true),
    PaymentMethod(id: 'internet',     country: 'BR', flag: '🇧🇷', name: 'Internet',   currency: 'BRL', icon: Icons.wifi,            active: true),
    PaymentMethod(id: 'mx_codi',      country: 'MX', flag: '🇲🇽', name: 'CoDi/SPEI',  currency: 'MXN', icon: Icons.payment,         active: false),
    PaymentMethod(id: 'ar_transf3',   country: 'AR', flag: '🇦🇷', name: 'Transf 3.0', currency: 'ARS', icon: Icons.payment,         active: true),
    PaymentMethod(id: 'co_breb',      country: 'CO', flag: '🇨🇴', name: 'Bre-B',      currency: 'COP', icon: Icons.payment,         active: false),
    PaymentMethod(id: 'in_upi',       country: 'IN', flag: '🇮🇳', name: 'UPI',        currency: 'INR', icon: Icons.payment,         active: false),
    PaymentMethod(id: 'th_promptpay', country: 'TH', flag: '🇹🇭', name: 'PromptPay',  currency: 'THB', icon: Icons.payment,         active: false),
  ];

  /// Lookup by id. Returns null for unknown ids.
  static PaymentMethod? byId(String? id) {
    if (id == null) return null;
    for (final m in kAll) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// All ids — used as default "all selected" for provider filter.
  static List<String> get allIds => kAll.map((m) => m.id).toList();

  /// IDs that currently have a working bill-code parser.
  /// These are the only ones that should be filter-selectable for now.
  static List<String> get activeIds =>
      kAll.where((m) => m.active).map((m) => m.id).toList();

  /// Display name fallback when id is unknown (e.g. legacy 'pix').
  static String displayName(String id) {
    final m = byId(id);
    if (m != null) return m.name;
    return id.toUpperCase();
  }

  /// Currency code for an id, defaults to BRL.
  static String currency(String id) => byId(id)?.currency ?? 'BRL';

  /// Flag emoji for an id, empty string if unknown.
  static String flag(String id) => byId(id)?.flag ?? '';

  /// Icon for an id.
  static IconData icon(String id) => byId(id)?.icon ?? Icons.payment;

  /// v603: Formats an amount in the order's ORIGINAL currency, so dashboard
  /// rows preserve the moeda the user actually paid in (R$ 12,50 for PIX,
  /// ARS 1.500,00 for Transf3, etc) instead of being converted to whatever
  /// the locale prefers.
  ///
  /// Symbols:
  ///   BRL -> "R$ 12,50"   (pt-BR style: comma decimal, dot thousands)
  ///   USD -> "$ 12.50"
  ///   EUR -> "€ 12.50"
  ///   ARS -> "ARS 1.500,00"
  ///   MXN -> "MXN 250.00"
  ///   COP -> "COP 25.000"
  ///   INR -> "INR 1,000.00"
  ///   THB -> "THB 100.00"
  ///   other -> "<CODE> 12.34"
  static String formatAmount(double amount, String currency) {
    final cur = currency.toUpperCase();
    String fmt(double v, {bool ptBr = false, int decimals = 2}) {
      final fixed = v.toStringAsFixed(decimals);
      final parts = fixed.split('.');
      final intPart = parts[0];
      final decPart = parts.length > 1 ? parts[1] : '';
      // thousands separator
      final buf = StringBuffer();
      for (var i = 0; i < intPart.length; i++) {
        if (i > 0 && (intPart.length - i) % 3 == 0) {
          buf.write(ptBr ? '.' : ',');
        }
        buf.write(intPart[i]);
      }
      if (decimals == 0) return buf.toString();
      return '${buf.toString()}${ptBr ? ',' : '.'}$decPart';
    }

    switch (cur) {
      case 'BRL':
        return 'R\$ ${fmt(amount, ptBr: true)}';
      case 'USD':
        return '\$ ${fmt(amount)}';
      case 'EUR':
        return '€ ${fmt(amount)}';
      case 'ARS':
        return 'ARS ${fmt(amount, ptBr: true)}';
      case 'MXN':
        return 'MXN ${fmt(amount)}';
      case 'COP':
        // COP usualmente sem decimais
        return 'COP ${fmt(amount, ptBr: true, decimals: 0)}';
      case 'INR':
        return 'INR ${fmt(amount)}';
      case 'THB':
        return 'THB ${fmt(amount)}';
      default:
        return '$cur ${fmt(amount)}';
    }
  }

  /// Groups used by the provider-filter UI. Brazilian bill types are
  /// merged into a single "Pix ou Boleto" entry so the user doesn't have
  /// to toggle 5 BR boxes.
  static const List<PaymentMethodGroup> kGroups = [
    PaymentMethodGroup(
      key: 'br',
      flag: '🇧🇷',
      label: 'Pix ou Boleto',
      currency: 'BRL',
      ids: ['pix', 'boleto', 'electricity', 'water', 'internet'],
      active: true,
    ),
    PaymentMethodGroup(key: 'mx', flag: '🇲🇽', label: 'CoDi/SPEI',  currency: 'MXN', ids: ['mx_codi'],      active: false),
    PaymentMethodGroup(key: 'ar', flag: '🇦🇷', label: 'Transf 3.0', currency: 'ARS', ids: ['ar_transf3'],   active: true),
    PaymentMethodGroup(key: 'co', flag: '🇨🇴', label: 'Bre-B',      currency: 'COP', ids: ['co_breb'],      active: false),
    PaymentMethodGroup(key: 'in', flag: '🇮🇳', label: 'UPI',        currency: 'INR', ids: ['in_upi'],       active: false),
    PaymentMethodGroup(key: 'th', flag: '🇹🇭', label: 'PromptPay',  currency: 'THB', ids: ['th_promptpay'], active: false),
  ];

  /// Returns the group that contains [id] (if any).
  static PaymentMethodGroup? groupForId(String? id) {
    if (id == null) return null;
    for (final g in kGroups) {
      if (g.ids.contains(id)) return g;
    }
    return null;
  }
}

/// Visual grouping for the provider payment-method filter. A group bundles
/// one or more `PaymentMethod` ids that the provider toggles together.
class PaymentMethodGroup {
  final String key;
  final String flag;
  final String label;
  final String currency;
  final List<String> ids;
  final bool active;

  const PaymentMethodGroup({
    required this.key,
    required this.flag,
    required this.label,
    required this.currency,
    required this.ids,
    required this.active,
  });
}

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
    PaymentMethod(id: 'ar_transf3',   country: 'AR', flag: '🇦🇷', name: 'Transf 3.0', currency: 'ARS', icon: Icons.payment,         active: false),
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
}

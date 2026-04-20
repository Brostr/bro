import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// v525: Persistent push diagnostic log.
/// Release builds have `broLog` gated by `kDebugMode`, so iOS push issues
/// on TestFlight are invisible. This service stores the last ~50 events
/// in SharedPreferences so the user can screenshot them from Settings.
class PushDiag {
  static const _prefsKey = 'push_diag_events_v1';
  static const int _maxEvents = 50;

  static final List<String> _events = <String>[];
  static bool _loaded = false;

  /// Load persisted events from disk.
  static Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List).cast<String>();
        _events.addAll(list);
      }
    } catch (_) {
      // ignore
    }
  }

  /// Append an event. Safe to call from anywhere (fire-and-forget).
  static void log(String message) {
    // Best-effort: schedule async save, keep in-memory copy immediate.
    final ts = DateTime.now().toIso8601String().substring(11, 19); // HH:MM:SS
    final entry = '[$ts] $message';
    _appendSync(entry);
    _persist();
  }

  static void _appendSync(String entry) {
    _events.add(entry);
    while (_events.length > _maxEvents) {
      _events.removeAt(0);
    }
  }

  static Future<void> _persist() async {
    try {
      await _ensureLoaded();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(_events));
    } catch (_) {
      // ignore
    }
  }

  /// Read all events (async; loads from disk on first call).
  static Future<List<String>> readAll() async {
    await _ensureLoaded();
    return List<String>.from(_events);
  }

  /// Clear the log.
  static Future<void> clear() async {
    _events.clear();
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {}
  }
}

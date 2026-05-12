// v582: Tela de diagnóstico para inspecionar/exportar logs in-app.
// Buffer mora em RAM (BroLogBuffer) — não é persistido em disco.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/log_utils.dart';
import '../l10n/app_localizations.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({Key? key}) : super(key: key);

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  late List<String> _entries;
  String _version = '';

  @override
  void initState() {
    super.initState();
    _entries = BroLogBuffer.instance.snapshot();
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() => _version = '${info.version}+${info.buildNumber}');
    });
  }

  void _refresh() {
    setState(() => _entries = BroLogBuffer.instance.snapshot());
  }

  String _buildHeader() => '=== Bro Diagnostics ===\n'
      'Version: $_version\n'
      'Generated: ${DateTime.now().toIso8601String()}\n'
      'Entries: ${_entries.length}\n'
      '=======================\n';

  Future<void> _copy() async {
    final text = '${_buildHeader()}\n${_entries.join('\n')}';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).t('diag_copied')),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _share() async {
    final text = '${_buildHeader()}\n${_entries.join('\n')}';
    await Share.share(text, subject: 'Bro logs $_version');
  }

  void _clear() {
    BroLogBuffer.instance.clear();
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(t.t('diag_title'), style: const TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: t.t('diag_refresh'),
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: const Color(0xFF1A1A1A),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$_version  ·  ${_entries.length} ${t.t('diag_entries')}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  t.t('diag_hint'),
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
          Expanded(
            child: _entries.isEmpty
                ? Center(
                    child: Text(
                      t.t('diag_empty'),
                      style: const TextStyle(color: Colors.white38),
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(8),
                    itemCount: _entries.length,
                    itemBuilder: (ctx, i) {
                      final entry = _entries[_entries.length - 1 - i];
                      return Container(
                        margin: const EdgeInsets.symmetric(vertical: 2),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF111111),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: SelectableText(
                          entry,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.all(8),
              color: const Color(0xFF1A1A1A),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _copy,
                      icon: const Icon(Icons.copy, size: 16, color: Colors.cyan),
                      label: Text(t.t('diag_copy'), style: const TextStyle(color: Colors.cyan)),
                      style: OutlinedButton.styleFrom(side: BorderSide(color: Colors.cyan.withOpacity(0.4))),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _share,
                      icon: const Icon(Icons.share, size: 16),
                      label: Text(t.t('diag_share')),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: t.t('diag_clear'),
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    onPressed: _clear,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

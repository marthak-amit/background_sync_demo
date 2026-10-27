import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Flutter is UI only: all timers and Firebase writes live in native Kotlin / Swift.
const _control = MethodChannel('sync/control');
const _logs = EventChannel('sync/logs');

void main() => runApp(const SyncApp());

class SyncApp extends StatelessWidget {
  const SyncApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Background Sync Demo',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  Map<String, dynamic> _status = {};
  List<Map<String, dynamic>> _perms = [];
  List<Map<String, dynamic>> _rows = [];
  String? _logError;
  Timer? _poll;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    _sub = _logs.receiveBroadcastStream().listen(
      (e) => setState(() {
        _logError = null;
        _rows = (e as List).map((r) => Map<String, dynamic>.from(r as Map)).toList();
      }),
      onError: (e) => setState(() => _logError = '$e'),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final s = Map<String, dynamic>.from(await _control.invokeMethod('status') as Map);
      final p = (await _control.invokeMethod('permissions') as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (mounted) setState(() { _status = s; _perms = p; });
    } catch (_) {}
  }

  bool get _running => _status['running'] == true;

  Future<void> _toggle() async {
    await _control.invokeMethod(_running ? 'stop' : 'start');
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final last = (_status['lastWriteAt'] as num?)?.toInt() ?? 0;
    final lastStr = last == 0
        ? '—'
        : DateTime.fromMillisecondsSinceEpoch(last).toLocal().toString().substring(11, 19);
    final layers = ((_status['layers'] as List?) ?? []).cast<Map>();
    return Scaffold(
      appBar: AppBar(title: const Text('Background Sync Demo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _toggle,
                style: FilledButton.styleFrom(
                  backgroundColor: _running ? Colors.red : Colors.green,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                icon: Icon(_running ? Icons.stop : Icons.play_arrow),
                label: Text(_running ? 'Stop sync' : 'Start sync'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              title: Text('Current n: ${_status['n'] ?? 0}  (Test_${_status['n'] ?? 0})'),
              subtitle: Text('Last write: $lastStr · state: ${_status['lastAppState'] ?? '-'}'
                  ' · queued offline: ${_status['pending'] ?? 0}'),
            ),
          ),
          const _Header('Permission checklist'),
          for (final p in _perms)
            ListTile(
              dense: true,
              leading: Icon(p['ok'] == true ? Icons.check_circle : Icons.cancel,
                  color: p['ok'] == true ? Colors.green : Colors.red),
              title: Text('${p['label']}'),
              subtitle: Text('${p['hint']}'),
              trailing: p['ok'] == true && p['id'] != 'oem'
                  ? null
                  : TextButton(
                      onPressed: () async {
                        await _control.invokeMethod('fix', p['id']);
                        await _refresh();
                      },
                      child: const Text('Fix'),
                    ),
            ),
          const _Header('Active layers'),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final l in layers)
              Chip(
                avatar: Icon(l['ok'] == true ? Icons.check_circle : Icons.cancel,
                    size: 18, color: l['ok'] == true ? Colors.green : Colors.red),
                label: Text('${l['name']}', style: const TextStyle(fontSize: 12)),
              ),
          ]),
          const _Header('Last 30 records (Firebase, live)'),
          if (_logError != null) Text(_logError!, style: const TextStyle(color: Colors.red)),
          for (final r in _rows) _LogTile(r),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 6),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _LogTile extends StatelessWidget {
  const _LogTile(this.r);
  final Map<String, dynamic> r;
  @override
  Widget build(BuildContext context) {
    final gap = (r['gapSeconds'] as num?)?.toInt() ?? 0;
    final bad = gap > 90;
    final t = (r['timestamp'] ?? r['clientTime']) as num?;
    final time = t == null
        ? '…'
        : DateTime.fromMillisecondsSinceEpoch(t.toInt()).toLocal().toString().substring(11, 19);
    return Container(
      color: bad ? Colors.red.withValues(alpha: 0.18) : null,
      child: ListTile(
        dense: true,
        title: Text('${r['value']}  ·  ${r['appState']}'),
        subtitle: Text('$time · ${r['platform']}'),
        trailing: Text('gap ${gap}s',
            style: TextStyle(color: bad ? Colors.red : null, fontWeight: bad ? FontWeight.bold : null)),
      ),
    );
  }
}

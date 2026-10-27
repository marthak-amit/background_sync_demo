import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

/// Flutter is UI only: all timers and Firebase writes live in native Kotlin / Swift.
const _control = MethodChannel('sync/control');
const _logs = EventChannel('sync/logs');
const _postsChannel = EventChannel('sync/posts');

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
  List<Map<String, dynamic>> _posts = [];
  String? _logError;
  Timer? _poll;
  StreamSubscription? _sub;
  StreamSubscription? _postSub;
  final _text = TextEditingController();
  String? _pickedPath;
  bool _submitting = false;

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
    _postSub = _postsChannel.receiveBroadcastStream().listen(
      (e) => setState(() => _posts =
          (e as List).map((r) => Map<String, dynamic>.from(r as Map)).toList()),
      onError: (_) {},
    );
  }

  Future<void> _pick() async {
    // Compressed on pick so the queued file is small and uploads fast on a weak connection.
    final x = await ImagePicker().pickImage(
        source: ImageSource.gallery, maxWidth: 1600, maxHeight: 1600, imageQuality: 80);
    if (x != null) setState(() => _pickedPath = x.path);
  }

  Future<void> _submit() async {
    if (_text.text.trim().isEmpty && _pickedPath == null) return;
    setState(() => _submitting = true);
    try {
      // Native copies the image into its own outbox and uploads when a network exists (offline is fine).
      await _control.invokeMethod('submitPost', {'text': _text.text, 'path': _pickedPath});
      _text.clear();
      setState(() => _pickedPath = null);
      await _refresh();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _sub?.cancel();
    _postSub?.cancel();
    _text.dispose();
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
          const _Header('New post (works offline)'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Text', border: OutlineInputBorder()),
                ),
                if (_pickedPath != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Image.file(File(_pickedPath!), height: 120, fit: BoxFit.cover),
                  ),
                const SizedBox(height: 8),
                Row(children: [
                  OutlinedButton.icon(
                      onPressed: _pick, icon: const Icon(Icons.image), label: Text(_pickedPath == null ? 'Pick image' : 'Change image')),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                      onPressed: _submitting ? null : _submit, icon: const Icon(Icons.cloud_upload), label: const Text('Submit')),
                ]),
                if (!_running)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('Tip: tap Start sync so queued posts also upload while the app is closed.',
                        style: TextStyle(fontSize: 12)),
                  ),
              ]),
            ),
          ),
          if (((_status['outbox'] as List?) ?? []).isNotEmpty) const _Header('Waiting to upload'),
          for (final o in ((_status['outbox'] as List?) ?? []).cast<Map>())
            _PostTile(Map<String, dynamic>.from(o), queued: true),
          const _Header('Posts'),
          for (final p in _posts) _PostTile(p, queued: p['pendingWrite'] == true),
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
    final t = (r['clientTime'] ?? r['timestamp']) as num?;
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

class _PostTile extends StatelessWidget {
  const _PostTile(this.p, {required this.queued});
  final Map<String, dynamic> p;
  final bool queued;

  @override
  Widget build(BuildContext context) {
    final local = p['imagePath'] is String && File(p['imagePath'] as String).existsSync();
    final url = p['imageUrl'] as String?;
    final t = (p['clientTime'] as num?)?.toInt();
    final time = t == null ? '' : DateTime.fromMillisecondsSinceEpoch(t).toLocal().toString().substring(0, 19);
    Widget? thumb;
    if (queued && local) {
      thumb = Image.file(File(p['imagePath'] as String), width: 56, height: 56, fit: BoxFit.cover);
    } else if (url != null && url.isNotEmpty) {
      thumb = Image.network(url, width: 56, height: 56, fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image));
    }
    return Card(
      child: ListTile(
        leading: thumb,
        title: Text((p['text'] as String?)?.isEmpty ?? true ? '(image)' : p['text'] as String),
        subtitle: Text(time),
        trailing: queued
            ? const Chip(label: Text('queued', style: TextStyle(fontSize: 11)), avatar: Icon(Icons.schedule, size: 16))
            : const Icon(Icons.cloud_done, color: Colors.green),
      ),
    );
  }
}

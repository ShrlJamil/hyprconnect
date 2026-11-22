//! M2: send clipboard text to a device (kdeconnect.clipboard) and show
//! the last clipboard text received from it. Sending reads what the
//! user typed or pasted; receiving sets the phone clipboard the moment
//! the packet arrives (see AppState.handleIncomingPacket).

import 'package:flutter/material.dart';

import 'app_state.dart';

String _formatTime(DateTime t) {
  final local = t.toLocal().toString();
  return local.length >= 16 ? local.substring(0, 16) : local;
}

class ClipboardPage extends StatefulWidget {
  final AppState appState;
  final DeviceListEntry entry;

  const ClipboardPage({
    super.key,
    required this.appState,
    required this.entry,
  });

  @override
  State<ClipboardPage> createState() => _ClipboardPageState();
}

class _ClipboardPageState extends State<ClipboardPage> {
  final _controller = TextEditingController();
  String? _status;
  bool _sending = false;

  AppState get _appState => widget.appState;
  DeviceListEntry get _entry => widget.entry;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final text = await _appState.readClipboardText();
    if (!mounted) return;
    if (text == null || text.isEmpty) {
      setState(() => _status = 'Papan klip kosong atau bukan teks.');
      return;
    }
    setState(() {
      _controller.text = text;
      _status = null;
    });
  }

  Future<void> _send() async {
    final content = _controller.text;
    if (content.isEmpty) {
      setState(() => _status = 'Tulis dulu isi papan klip.');
      return;
    }
    setState(() {
      _sending = true;
      _status = 'Mengirim...';
    });
    try {
      final sent = await _appState.sendClipboard(_entry.deviceId, content);
      if (!mounted) return;
      setState(
        () => _status = sent
            ? 'Terkirim (${content.length} karakter)'
            : 'Tidak ada koneksi ke perangkat ini.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Gagal mengirim: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _entry.name.isEmpty ? _entry.deviceId : _entry.name;
    return AnimatedBuilder(
      animation: _appState,
      builder: (context, _) {
        final received = _appState.lastReceivedClipboard;
        final from = _appState.lastReceivedFrom;
        final at = _appState.lastReceivedAt;
        return Scaffold(
          appBar: AppBar(title: const Text('Kirim papan klip')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Kirim ke $name',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _controller,
                maxLines: 6,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Tulis atau tempel isi papan klip di sini',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _sending ? null : _paste,
                      child: const Text('Tempel dari papan klip'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: _sending ? null : _send,
                      child: const Text('Kirim'),
                    ),
                  ),
                ],
              ),
              if (_status != null) ...[
                const SizedBox(height: 12),
                Text(_status!),
              ],
              const SizedBox(height: 24),
              Text(
                'Terakhir diterima',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (received == null)
                const Card(
                  child: ListTile(
                    title: Text('Belum ada papan klip diterima'),
                    subtitle: Text(
                      'Begitu desktop mengirim papan klipnya, isinya '
                      'langsung masuk ke papan klip HP ini.',
                    ),
                  ),
                )
              else
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (from != null && from.isNotEmpty)
                          Text(
                            'Dari $from'
                            '${at == null ? '' : ' - ${_formatTime(at)}'}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        const SizedBox(height: 8),
                        SelectableText(received),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

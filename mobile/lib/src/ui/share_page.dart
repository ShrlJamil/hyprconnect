//! M2: send a file to a device (share.request + payload upload) and
//! list the files received from it. Picking uses the system picker
//! (Storage Access Framework on Android), so no storage permission is
//! needed for a user-picked file. Files the desktop sends land in the
//! app's receive dir (see AppState.receiveDirPath).

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';

String _formatBytes(int n) {
  if (n < 1024) return '$n byte';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
}

String _formatTime(DateTime t) {
  final local = t.toLocal().toString();
  return local.length >= 16 ? local.substring(0, 16) : local;
}

class SharePage extends StatefulWidget {
  final AppState appState;
  final DeviceListEntry entry;

  const SharePage({super.key, required this.appState, required this.entry});

  @override
  State<SharePage> createState() => _SharePageState();
}

class _SharePageState extends State<SharePage> {
  PlatformFile? _picked;
  int? _pickedSize;
  String? _status;
  double? _progress;
  bool _sending = false;

  AppState get _appState => widget.appState;
  DeviceListEntry get _entry => widget.entry;

  Future<void> _pick() async {
    final picked = await FilePicker.pickFile();
    if (picked == null) return;
    final size = await picked.length();
    setState(() {
      _picked = picked;
      _pickedSize = size;
      _status = null;
      _progress = null;
    });
  }

  Future<void> _send() async {
    final picked = _picked;
    if (picked == null) return;
    // Size first (the picker usually knows it); without it, read the
    // whole file once so the payload size is exact.
    final buffered = await picked.length().then((n) async {
      if (n != null) return null;
      return picked.readAsBytes();
    });
    final size = buffered?.length ?? _pickedSize ?? 0;
    final Stream<List<int>> bytes = buffered != null
        ? Stream<List<int>>.value(buffered)
        : picked.readAsByteStream();
    setState(() {
      _sending = true;
      _status = 'Mengirim ${picked.name}...';
      _progress = 0;
    });
    try {
      await _appState.sendFile(
        _entry.deviceId,
        filename: picked.name,
        size: size,
        bytes: bytes,
        onProgress: (sent) {
          if (!mounted) return;
          setState(() => _progress = size == 0 ? 1 : sent / size);
        },
      );
      if (!mounted) return;
      setState(
        () => _status = 'Terkirim: ${picked.name} (${_formatBytes(size)})',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Gagal mengirim: $e');
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _progress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _entry.name.isEmpty ? _entry.deviceId : _entry.name;
    return AnimatedBuilder(
      animation: _appState,
      builder: (context, _) {
        final received = _appState.receivedFilesFor(_entry.deviceId);
        final picked = _picked;
        return Scaffold(
          appBar: AppBar(title: const Text('Kirim file')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Kirim ke $name',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        picked == null
                            ? 'Belum ada file dipilih.'
                            : _pickedSize == null
                            ? picked.name
                            : '${picked.name} (${_formatBytes(_pickedSize!)})',
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _sending ? null : _pick,
                              child: const Text('Pilih file'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton(
                              onPressed:
                                  (_sending || picked == null) ? null : _send,
                              child: const Text('Kirim'),
                            ),
                          ),
                        ],
                      ),
                      if (_progress != null) ...[
                        const SizedBox(height: 12),
                        LinearProgressIndicator(value: _progress),
                      ],
                      if (_status != null) ...[
                        const SizedBox(height: 12),
                        Text(_status!),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Diterima dari $name',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (received.isEmpty)
                const ListTile(
                  title: Text('Belum ada file diterima dari perangkat ini'),
                  subtitle: Text(
                    'File yang dikirim desktop muncul di sini dan '
                    'tersimpan di HP.',
                  ),
                ),
              for (final file in received)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.insert_drive_file, size: 32),
                    title: Text(file.filename),
                    subtitle: Text(
                      '${_formatBytes(file.size)} - ${_formatTime(file.receivedAt)}\n${file.path}',
                    ),
                    isThreeLine: true,
                  ),
                ),
              const SizedBox(height: 16),
              Text(
                'File yang dikirim desktop tersimpan di:\n'
                '${_appState.receiveDirPath ?? 'menyiapkan folder...'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}

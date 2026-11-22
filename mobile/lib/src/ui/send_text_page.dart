//! Send a whole text to the desktop as keystrokes in one go (the
//! stock app's "send keystrokes" action). Unlike the keyboard page,
//! nothing is sent while typing; the Kirim button types the whole
//! field on the desktop at once.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

import 'app_state.dart';

class SendTextPage extends StatefulWidget {
  final AppState appState;
  final DeviceListEntry entry;

  const SendTextPage({super.key, required this.appState, required this.entry});

  @override
  State<SendTextPage> createState() => _SendTextPageState();
}

class _SendTextPageState extends State<SendTextPage> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text;
    if (text.isEmpty) return;
    widget.appState.sendMousepadType(widget.entry.deviceId, text);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.sendText),
            Text(
              widget.entry.name,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('send-text-field'),
              controller: _controller,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              decoration: InputDecoration(
                labelText: context.l10n.textToTypeLabel,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Teks diketik apa adanya di desktop, termasuk baris '
              'baru yang menjadi Enter.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.send),
              label: Text(context.l10n.send),
              onPressed: _send,
            ),
          ],
        ),
      ),
    );
  }
}

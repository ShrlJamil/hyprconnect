//! Slide-notes editor, modelled on HyprPresenter's notebook-style
//! editor: one bordered cell per slide stacked vertically, a wide
//! "+" tile under the last cell adds another slide, and every
//! keystroke is saved immediately, so leaving at any point loses
//! nothing. Notes live on this phone only, per device, in the
//! Markdown interchange format (see slide_notes.dart).

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'slide_notes.dart';

class NotesEditorPage extends StatefulWidget {
  final AppState appState;
  final String deviceId;

  const NotesEditorPage({
    super.key,
    required this.appState,
    required this.deviceId,
  });

  @override
  State<NotesEditorPage> createState() => _NotesEditorPageState();
}

class _NotesEditorPageState extends State<NotesEditorPage> {
  final List<TextEditingController> _cells = [];

  @override
  void initState() {
    super.initState();
    final notes = parseSlideNotes(
      widget.appState.presenterNotesFor(widget.deviceId),
    );
    for (final note in notes) {
      _cells.add(TextEditingController(text: note));
    }
    if (_cells.isEmpty) {
      _cells.add(TextEditingController());
    }
  }

  @override
  void dispose() {
    for (final cell in _cells) {
      cell.dispose();
    }
    super.dispose();
  }

  /// Persist the cells as one Markdown document. Trailing empty
  /// cells are editing headroom, not slides, so they are left out.
  void _persist() {
    final texts = _cells.map((c) => c.text).toList();
    while (texts.isNotEmpty && texts.last.trim().isEmpty) {
      texts.removeLast();
    }
    widget.appState.savePresenterNotes(
      widget.deviceId,
      texts.isEmpty ? '' : serializeSlideNotes(texts),
    );
  }

  void _addSlide() {
    setState(() => _cells.add(TextEditingController()));
  }

  Future<void> _openFile() async {
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['md', 'txt'],
      );
      if (picked == null || picked.path == null) return;
      final notes = parseSlideNotes(await File(picked.path!).readAsString());
      if (!mounted) return;
      setState(() {
        for (final cell in _cells) {
          cell.dispose();
        }
        _cells
          ..clear()
          ..addAll(notes.map((n) => TextEditingController(text: n)));
        if (_cells.isEmpty) _cells.add(TextEditingController());
      });
      _persist();
    } catch (_) {
      // Cancelled or unreadable: the current notes stay as they are.
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Catatan slide'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open_outlined),
            tooltip: 'Buka file catatan',
            onPressed: _openFile,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (var i = 0; i < _cells.length; i++) ...[
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  TextField(
                    controller: _cells[i],
                    maxLines: null,
                    minLines: 2,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Catatan untuk slide ini',
                    ),
                    onChanged: (_) => _persist(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          OutlinedButton.icon(
            onPressed: _addSlide,
            icon: const Icon(Icons.add),
            label: const Text('Tambah slide'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
          ),
        ],
      ),
    );
  }
}

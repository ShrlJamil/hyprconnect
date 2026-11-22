//! Per-slide presenter notes: parsing and serialization.
//!
//! The format is the same Markdown interchange HyprPresenter uses,
//! so a notes file works in both apps: one `## N` heading per slide
//! with the note text below it. The parser is deliberately
//! forgiving: `## 1`, `## Slide 1`, and `---` separators are all
//! accepted, and a document with neither is a single note for
//! slide 1.

final RegExp _headingPattern = RegExp(
  r'^#{1,6}\s*(?:slide\s*)?(\d+)\s*$',
  caseSensitive: false,
);
final RegExp _separatorPattern = RegExp(r'^\s*(?:-{3,}|\*{3,})\s*$');

/// Parse a notes document into one entry per slide (index 0 = slide 1).
///
/// Numbered headings win when present: missing numbers become empty
/// notes, so numbering never shifts. Without headings, `---`
/// separators split the document in order.
List<String> parseSlideNotes(String source) {
  final lines = source.split('\n');

  final byNumber = <int, List<String>>{};
  int? current;
  for (final line in lines) {
    final match = _headingPattern.firstMatch(line.trim());
    if (match != null) {
      current = int.parse(match.group(1)!);
      byNumber.putIfAbsent(current, () => <String>[]);
    } else if (current != null) {
      byNumber[current]!.add(line);
    }
  }
  if (byNumber.isNotEmpty) {
    var highest = 0;
    for (final n in byNumber.keys) {
      if (n > highest) highest = n;
    }
    return <String>[
      for (var i = 1; i <= highest; i++)
        (byNumber[i] ?? const <String>[]).join('\n').trim(),
    ];
  }

  if (lines.any(_separatorPattern.hasMatch)) {
    final parts = <List<String>>[<String>[]];
    for (final line in lines) {
      if (_separatorPattern.hasMatch(line)) {
        parts.add(<String>[]);
      } else {
        parts.last.add(line);
      }
    }
    final notes = parts.map((p) => p.join('\n').trim()).toList();
    while (notes.isNotEmpty && notes.first.isEmpty) {
      notes.removeAt(0);
    }
    while (notes.isNotEmpty && notes.last.isEmpty) {
      notes.removeLast();
    }
    return notes;
  }

  final whole = source.trim();
  return whole.isEmpty ? <String>[] : <String>[whole];
}

/// Render notes back to the Markdown interchange format.
String serializeSlideNotes(List<String> notes) {
  final buffer = StringBuffer();
  for (var i = 0; i < notes.length; i++) {
    if (i > 0) buffer.writeln();
    buffer.writeln('## ${i + 1}');
    buffer.writeln();
    final body = notes[i].trim();
    if (body.isNotEmpty) {
      buffer.writeln(body);
      buffer.writeln();
    }
  }
  return '${buffer.toString().trimRight()}\n';
}

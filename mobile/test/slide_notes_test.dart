import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/ui/slide_notes.dart';

void main() {
  group('parseSlideNotes', () {
    test('numbered headings win and keep numbering', () {
      final notes = parseSlideNotes('## 1\n\nHalo\n\n## 3\n\nLewat\n');
      expect(notes, ['Halo', '', 'Lewat']);
    });

    test('slide wording in headings is accepted', () {
      expect(parseSlideNotes('## Slide 2\nIsi'), ['', 'Isi']);
    });

    test('separators split in order', () {
      expect(parseSlideNotes('Satu\n\n---\n\nDua'), ['Satu', 'Dua']);
    });

    test('a plain document is one note for slide 1', () {
      expect(parseSlideNotes('  Catatan bebas  '), ['Catatan bebas']);
    });

    test('an empty document has no notes', () {
      expect(parseSlideNotes('   \n'), isEmpty);
    });
  });

  group('serializeSlideNotes', () {
    test('round-trips through the parser', () {
      final notes = ['Pembuka', '', 'Penutup dengan\ndua baris'];
      expect(parseSlideNotes(serializeSlideNotes(notes)), notes);
    });
  });
}

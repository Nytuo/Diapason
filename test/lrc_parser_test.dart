import 'package:diapason/services/lyrics/lrc_parser.dart';
import 'package:flutter_test/flutter_test.dart';

Duration _startOf(int ticks) => Duration(microseconds: ticks ~/ 10);

void main() {
  group('LRC timestamps', () {
    test('one, two and three fraction digits mean tenths, hundredths and thousandths', () {
      final lyrics = LrcParser.parse("[00:01.5]a\n[00:02.25]b\n[00:03.125]c\n[00:04]d\n[00:05.1234]e")!.lyrics!;
      expect(lyrics.map((l) => _startOf(l.start!)).toList(), [
        const Duration(seconds: 1, milliseconds: 500),
        const Duration(seconds: 2, milliseconds: 250),
        const Duration(seconds: 3, milliseconds: 125),
        const Duration(seconds: 4),
        const Duration(seconds: 5, milliseconds: 123),
      ]);
    });

    test('a line with several timestamps is shown at each of them, in order', () {
      final lyrics = LrcParser.parse("[00:10.00][00:30.00]Chorus\n[00:20.00]Verse")!.lyrics!;
      expect(lyrics.map((l) => l.text).toList(), ['Chorus', 'Verse', 'Chorus']);
      expect(lyrics.map((l) => _startOf(l.start!).inSeconds).toList(), [10, 20, 30]);
    });

    test('metadata tags and untimed lines are skipped', () {
      final lyrics = LrcParser.parse("[ar:Someone]\n[ti:Song]\nno time here\n[00:01.00]Line")!.lyrics!;
      expect(lyrics.single.text, 'Line');
    });

    test('nothing timed means no synced lyrics', () {
      expect(LrcParser.parse("just\nwords"), isNull);
    });
  });
}

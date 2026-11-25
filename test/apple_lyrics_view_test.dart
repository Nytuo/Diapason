import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:diapason/components/lyrics/apple_lyrics_view.dart';
import 'package:diapason/components/lyrics/lyric_text.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/lyrics/lyrics_extras.dart';
import 'package:diapason/services/progress_state_stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

int _t(int ms) => ms * 10000;

void main() {
  final lines = [
    LyricLine(
      text: "one two",
      start: _t(5000),
      cues: [
        LyricLineCue(position: 0, start: _t(5000), end: _t(6000)),
        LyricLineCue(position: 4, start: _t(6000), end: _t(7000)),
      ],
    ),
    LyricLine(text: "second line", start: _t(12000)),
    LyricLine(text: "", start: _t(14000)),
    LyricLine(text: "after the break", start: _t(20000)),
    LyricLine(text: "", start: _t(21000)),
    LyricLine(text: "right away", start: _t(22000)),
  ];

  test("rows: intro, gap after word-timed line, long blank line; short blank dropped", () {
    final items = LyricsDisplayItem.build(lines);
    String describe(LyricsDisplayItem i) =>
        i.isInterlude ? "~${i.startMicros ~/ 1000}-${i.endMicros ~/ 1000}" : "${i.lineIndex}";
    expect(items.map(describe), ["~0-5000", "0", "~7000-12000", "1", "~14000-20000", "3", "5"]);
    expect(LyricsDisplayItem.activeAt(items, 1000000), 0);
    expect(LyricsDisplayItem.activeAt(items, 6500000), 1);
    expect(LyricsDisplayItem.activeAt(items, 8000000), 2);
    expect(LyricsDisplayItem.activeAt(items, 30000000), items.length - 1);
  });

  test("fill: per word with cues, swept over the line without", () {
    expect(LyricFill.at(lines[0], 4000000), LyricFill.none);
    expect(LyricFill.at(lines[0], 6500000), const LyricFill(litEnd: 4, wordStart: 4, wordEnd: 7, progress: 0.5));
    expect(LyricFill.at(lines[0], 8000000), const LyricFill(litEnd: 7));
    final line = LyricFill.at(lines[1], 13000000, lineEndMicros: 14000000);
    expect(line.wordEnd, "second line".length);
    // A short line is swept over ~1.5 s, not the whole time until the next one.
    expect(line.progress, closeTo(2 / 3, 0.01));
    expect(LyricFill.at(lines[1], 15000000, lineEndMicros: 14000000).litEnd, "second line".length);
  });

  testWidgets("follows playback and seeks on tap", (tester) async {
    final progress = StreamController<ProgressState>();
    LyricLine? sought;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppleLyricsView(
            lines: lines,
            extras: LyricsExtras.none,
            style: const TextStyle(fontSize: 24, color: Colors.white),
            textAlign: TextAlign.start,
            offsetMicros: () => 0,
            onSeek: (line) => sought = line,
            progress: progress.stream,
          ),
        ),
      ),
    );
    progress.add(
      ProgressState(
        null,
        PlaybackState(processingState: AudioProcessingState.ready, updatePosition: const Duration(seconds: 6)),
        const Duration(seconds: 6),
      ),
    );
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final active = tester.widgetList<LyricText>(find.byType(LyricText)).where((t) => t.fill != null).toList();
    expect(active.map((t) => t.text), ["one two"]);

    await tester.tap(find.byWidgetPredicate((w) => w is LyricText && w.text == "second line"));
    expect(sought, same(lines[1]));
    await progress.close();
  });
}

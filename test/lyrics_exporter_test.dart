import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/lyrics/lrc_parser.dart';
import 'package:diapason/services/lyrics/lyrics_exporter.dart';
import 'package:flutter_test/flutter_test.dart';

int _ticks(int ms) => ms * 10000;

void main() {
  final synced = [
    LyricLine(text: "Hello darkness", start: _ticks(12340)),
    LyricLine(text: "", start: _ticks(15000)),
    LyricLine(text: "my old friend", start: _ticks(61005)),
  ];
  const metadata = LyricsExportMetadata(
    title: "The Sound",
    artist: "Simon [&] Garfunkel",
    album: "Sounds",
    length: Duration(minutes: 3, seconds: 5),
  );

  test("LRC with tags", () {
    expect(
      LyricsExporter.toLrc(synced, metadata: metadata),
      "[ar:Simon & Garfunkel]\n"
      "[ti:The Sound]\n"
      "[al:Sounds]\n"
      "[length:03:05]\n"
      "[00:12.34]Hello darkness\n"
      "[00:15.00]\n"
      "[01:01.01]my old friend\n",
    );
  });

  test("LRC bakes the offset in and never goes negative", () {
    final lrc = LyricsExporter.toLrc(synced, offsetMs: -13000);
    expect(lrc.split("\n").take(3), ["[00:00.00]Hello darkness", "[00:02.00]", "[00:48.01]my old friend"]);
  });

  test("enhanced LRC round-trips through the parser", () {
    final line = LyricLine(
      text: "Look at the stars",
      start: _ticks(1000),
      cues: [
        LyricLineCue(position: 0, endPosition: 4, start: _ticks(1000), end: _ticks(1400)),
        LyricLineCue(position: 5, endPosition: 7, start: _ticks(1400), end: _ticks(1600)),
        LyricLineCue(position: 8, endPosition: 11, start: _ticks(1600), end: _ticks(1800)),
        LyricLineCue(position: 12, endPosition: 17, start: _ticks(1800), end: _ticks(2500)),
      ],
    );
    final lrc = LyricsExporter.toLrc([line], wordTimings: true);
    expect(lrc, "[00:01.00]<00:01.00>Look <00:01.40>at <00:01.60>the <00:01.80>stars<00:02.50>\n");
    final parsed = LrcParser.parse(lrc)!.lyrics!.single;
    expect(parsed.text, "Look at the stars");
    expect(parsed.cues!.map((c) => c.position), [0, 5, 8, 12]);
    expect(parsed.cues!.last.endMicros, 2500000);
  });

  test("SRT: lines end where the next starts, empty lines skipped", () {
    expect(
      LyricsExporter.toSrt(synced, length: metadata.length),
      "1\n00:00:12,340 --> 00:00:15,000\nHello darkness\n\n"
      "2\n00:01:01,005 --> 00:03:05,000\nmy old friend\n\n",
    );
  });

  test("SRT uses the last word's end when it's earlier", () {
    final srt = LyricsExporter.toSrt([
      LyricLine(
        text: "Hi",
        start: _ticks(0),
        cues: [LyricLineCue(position: 0, start: _ticks(0), end: _ticks(800))],
      ),
      LyricLine(text: "there", start: _ticks(5000)),
    ]);
    expect(srt.split("\n")[1], "00:00:00,000 --> 00:00:00,800");
    expect(srt.split("\n")[5], "00:00:05,000 --> 00:00:10,000");
  });

  test("TXT and file names", () {
    expect(LyricsExporter.toTxt(synced), "Hello darkness\n\nmy old friend\n");
    expect(LyricsExporter.fileName(metadata, LyricsExportFormat.srt), "Simon [&] Garfunkel - The Sound.srt");
    expect(
      LyricsExporter.fileName(const LyricsExportMetadata(title: "A/B: C?"), LyricsExportFormat.lrc),
      "A_B_ C_.lrc",
    );
    expect(LyricsExporter.fileName(const LyricsExportMetadata(), LyricsExportFormat.txt), "lyrics.txt");
  });

  test("formats offered depend on timings", () {
    final plain = [LyricLine(text: "a")];
    expect(LyricsExportFormat.lrc.availableFor(plain), isFalse);
    expect(LyricsExportFormat.txt.availableFor(plain), isTrue);
    expect(LyricsExportFormat.lrc.availableFor(synced), isTrue);
    expect(LyricsExportFormat.enhancedLrc.availableFor(synced), isFalse);
  });
}

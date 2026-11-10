import 'package:diapason/components/PlayerScreen/chapter_track.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ChapterInfo _chapter(Duration start, [String? name]) =>
    ChapterInfo(startPositionTicks: start.inMicroseconds * 10, name: name, imageDateModified: "");

/// The seek bar is split into one segment per chapter, YouTube-style.
void main() {
  const duration = Duration(minutes: 10);

  test('boundaries are the starts of every chapter but one at zero, as fractions of the track', () {
    final chapters = [
      _chapter(const Duration(minutes: 5), "Middle"),
      _chapter(Duration.zero, "Intro"),
      _chapter(const Duration(minutes: 2, seconds: 30), "Verse"),
    ];
    expect(chapterBoundaries(chapters, duration), [0.25, 0.5]);
  });

  test('chapters outside the track and an unknown duration give no boundaries', () {
    expect(chapterBoundaries([_chapter(const Duration(minutes: 12))], duration), isEmpty);
    expect(chapterBoundaries([_chapter(const Duration(minutes: 1))], Duration.zero), isEmpty);
  });

  test('a position falls in the segment after the last boundary it has passed', () {
    const boundaries = [0.25, 0.5];
    expect(segmentAt(boundaries, 0.0), 0);
    expect(segmentAt(boundaries, 0.25), 1);
    expect(segmentAt(boundaries, 0.49), 1);
    expect(segmentAt(boundaries, 0.99), 2);
  });

  testWidgets('a slider with the segmented track lays out and paints', (tester) async {
    for (final shape in const [
      ChapterTrackShape(),
      ChapterTrackShape(boundaries: [0.25, 0.5], hoveredSegment: 1),
      ChapterTrackShape(boundaries: [0.25, 0.5], rounded: false),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: SliderTheme(
                  data: SliderThemeData(trackShape: shape, trackHeight: 4),
                  child: Slider(value: 0.4, secondaryTrackValue: 0.6, onChanged: (_) {}),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(Slider), findsOneWidget);
    }
  });
}

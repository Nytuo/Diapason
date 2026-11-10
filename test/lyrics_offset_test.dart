import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/lyrics/lyrics_offset_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'support/test_env.dart';

void main() {
  late TestEnv env;
  const track = BaseItemId("jf-1~track");

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
    LyricsOffsetService.testBox = await Hive.openBox<int>(LyricsOffsetService.boxName);
  });

  tearDown(() async {
    LyricsOffsetService.testBox = null;
    await env.dispose();
  });

  test('nudges add up per track and are remembered', () async {
    await LyricsOffsetService.nudge(track, LyricsOffsetService.step);
    await LyricsOffsetService.nudge(track, LyricsOffsetService.step);
    expect(LyricsOffsetService.offsetMs(track), 1000);
    expect(LyricsOffsetService.offsetMs(const BaseItemId("jf-1~other")), 0);
  });

  test('back to zero forgets the track', () async {
    await LyricsOffsetService.nudge(track, 500);
    await LyricsOffsetService.nudge(track, -500);
    expect(LyricsOffsetService.all(), isEmpty);
  });

  test('offsets are capped', () async {
    await LyricsOffsetService.setOffset(track, 999999);
    expect(LyricsOffsetService.offsetMs(track), LyricsOffsetService.limit);
  });

  test('restoring from a backup brings the offsets back', () async {
    await LyricsOffsetService.restore({"a~1": 500, "b~2": -1500, "c~3": 0});
    expect(LyricsOffsetService.all(), {"a~1": 500, "b~2": -1500});
  });

  test('the label reads like a timing', () {
    expect(LyricsOffsetService.format(500), "+0.5 s");
    expect(LyricsOffsetService.format(-1500), "−1.5 s");
    expect(LyricsOffsetService.format(0), "0.0 s");
  });
}

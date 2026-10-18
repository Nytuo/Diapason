import 'package:audio_service/audio_service.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/automix/beat_analyzer.dart';
import 'package:diapason/services/automix_planner.dart';
import 'package:flutter_test/flutter_test.dart';

FinampQueueItem track(
  String id, {
  Duration length = const Duration(minutes: 4),
  String? album,
  int? number,
  int? disc,
  List<String>? genres,
}) {
  final item = BaseItemDto(
    id: BaseItemId(id),
    name: id,
    type: "Audio",
    albumId: album == null ? null : BaseItemId(album),
    indexNumber: number,
    parentIndexNumber: disc,
    genres: genres,
    runTimeTicks: length.inMicroseconds * 10,
  );
  return FinampQueueItem(
    item: MediaItem(id: id, title: id, duration: length, extras: {"itemJson": item.toJson()}),
    source: QueueItemSource.rawId(
      type: QueueItemSourceType.unknown,
      name: const QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: "t"),
      id: "t",
    ),
    type: QueueItemQueueType.queue,
  );
}

TransitionPlan? plan(FinampQueueItem a, FinampQueueItem b, {int crossfade = 0, bool automix = false}) =>
    AutomixPlanner.plan(
      current: a,
      next: b,
      currentDuration: a.item.duration!,
      crossfadeSeconds: crossfade,
      automix: automix,
    );

void main() {
  test("off means gapless", () {
    expect(plan(track("a"), track("b")), isNull);
  });

  test("plain crossfade uses the chosen length, but not on tracks too short for it", () {
    final fade = plan(track("a"), track("b"), crossfade: 6)!;
    expect(fade.duration, const Duration(seconds: 6));
    expect(fade.outEnd, const Duration(minutes: 4));
    expect(fade.style, TransitionStyle.crossfade);
    expect(plan(track("a", length: const Duration(seconds: 10)), track("b"), crossfade: 6), isNull);
  });

  test("automix keeps an album's consecutive tracks gapless, across discs too", () {
    expect(plan(track("a", album: "x", number: 3), track("b", album: "x", number: 4), automix: true), isNull);
    expect(
      plan(track("a", album: "x", number: 12, disc: 1), track("b", album: "x", number: 1, disc: 2), automix: true),
      isNull,
    );
    // Same album, but not the next track (shuffle): mix.
    expect(plan(track("a", album: "x", number: 3), track("b", album: "x", number: 9), automix: true), isNotNull);
  });

  test("automix leaves speech and classical alone", () {
    expect(plan(track("a", genres: ["Podcast"]), track("b"), automix: true), isNull);
    expect(plan(track("a"), track("b", genres: ["Classical"]), automix: true), isNull);
  });

  test("automix length follows the tracks, within 3 s and the crossfade setting", () {
    final shortish = plan(track("a", length: const Duration(seconds: 70)), track("b"), automix: true)!;
    expect(shortish.duration, const Duration(seconds: 3, milliseconds: 500));
    final long = plan(track("a", length: const Duration(minutes: 10)), track("b"), automix: true)!;
    expect(long.duration, const Duration(seconds: 6));
    final longer = plan(track("a", length: const Duration(minutes: 10)), track("b"), automix: true, crossfade: 12)!;
    expect(longer.duration, const Duration(seconds: 12));
  });

  test("curves start and end where they should and keep the power up in the middle", () {
    for (final p in [
      TransitionPlan.ending(const Duration(minutes: 3), const Duration(seconds: 6)),
      TransitionPlan.ending(const Duration(minutes: 3), const Duration(seconds: 6), style: TransitionStyle.smart),
    ]) {
      expect(p.fadeIn(0), closeTo(0, 1e-9));
      expect(p.fadeIn(1), closeTo(1, 1e-9));
      expect(p.fadeOut(0), closeTo(1, 1e-9));
      expect(p.fadeOut(1), closeTo(0, 1e-9));
      final mid = p.fadeIn(0.5) * p.fadeIn(0.5) + p.fadeOut(0.5) * p.fadeOut(0.5);
      expect(mid, greaterThanOrEqualTo(0.99));
    }
  });

  group("refining with the audio", () {
    /// A steady grid at [bpm] from [from] to [to] (seconds), bars starting on the first beat.
    BeatAnalysis grid(
      double bpm,
      double from,
      double to, {
      double? musicStart,
      double? musicEnd,
      double confidence = 0.6,
    }) {
      final beats = <double>[for (var t = from; t <= to; t += 60 / bpm) t];
      return BeatAnalysis(
        bpm: bpm,
        confidence: confidence,
        beats: beats,
        downbeats: [for (var i = 0; i < beats.length; i += 4) beats[i]],
        windowStart: from,
        windowEnd: to,
        musicStart: musicStart ?? from,
        musicEnd: musicEnd ?? to,
      );
    }

    final basic = TransitionPlan.ending(
      const Duration(seconds: 240),
      const Duration(seconds: 6),
      style: TransitionStyle.smart,
    );

    test("close tempos are beat matched over whole bars, ending on the last bar before the music stops", () {
      final out = grid(124, 195.0, 239.5, musicEnd: 236);
      final inn = grid(120, 0.5, 40, musicStart: 0.5);
      final plan = AutomixPlanner.refine(
        basic,
        currentDuration: const Duration(seconds: 240),
        outTail: out,
        inHead: inn,
      );

      expect(plan.style, TransitionStyle.beatMatched);
      expect(plan.speed, closeTo(124 / 120, 1e-9));
      expect(plan.outEnd.inMilliseconds / 1000, lessThanOrEqualTo(236.05));
      // 32 beats, i.e. 8 bars, starting and ending on a bar.
      expect(plan.inBeats.length, greaterThan(32));
      expect(out.downbeats, contains(out.beats[plan.outAnchor]));
      expect(plan.outStart.inMicroseconds / 1e6, closeTo(out.beats[plan.outAnchor], 1e-5));
      expect((plan.outEnd - plan.outStart).inMilliseconds / 1000, closeTo(32 * 60 / 124, 0.01));
      expect(plan.inCue.inMilliseconds / 1000, closeTo(0.5, 0.01));
    });

    test("half or double tempo counts as the same tempo", () {
      final out = grid(172, 195.0, 239.5);
      final inn = grid(87, 0.0, 40);
      final plan = AutomixPlanner.refine(
        basic,
        currentDuration: const Duration(seconds: 240),
        outTail: out,
        inHead: inn,
      );
      expect(plan.style, TransitionStyle.beatMatched);
      expect(plan.speed, closeTo(172 / 174, 1e-9));
    });

    test("tempos too far apart are not stretched; the mix still skips silence at both ends", () {
      final out = grid(90, 195.0, 239.5, musicEnd: 232);
      final inn = grid(140, 0.0, 40, musicStart: 2.0);
      final plan = AutomixPlanner.refine(
        basic,
        currentDuration: const Duration(seconds: 240),
        outTail: out,
        inHead: inn,
      );
      expect(plan.style, TransitionStyle.smart);
      expect(plan.speed, 1.0);
      expect(plan.outEnd.inMilliseconds / 1000, closeTo(232.3, 0.01));
      expect(plan.duration, const Duration(seconds: 6));
      expect(plan.inCue, const Duration(seconds: 2));
    });

    test("no clear beat: no beat matching", () {
      final out = grid(120, 195.0, 239.5, confidence: 0.05);
      final inn = grid(120, 0.0, 40);
      final plan = AutomixPlanner.refine(
        basic,
        currentDuration: const Duration(seconds: 240),
        outTail: out,
        inHead: inn,
      );
      expect(plan.style, TransitionStyle.smart);
    });

    test("a plain crossfade is left alone", () {
      final crossfade = TransitionPlan.ending(const Duration(seconds: 240), const Duration(seconds: 6));
      expect(
        AutomixPlanner.refine(
          crossfade,
          currentDuration: const Duration(seconds: 240),
          outTail: grid(120, 195, 239),
          inHead: grid(120, 0, 40),
        ),
        same(crossfade),
      );
    });
  });
}

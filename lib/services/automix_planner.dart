import 'dart:math';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/automix/beat_analyzer.dart';

enum TransitionStyle {
  /// A plain equal-power crossfade of a fixed length.
  crossfade,

  /// Automix without beat matching: placed where the music actually ends and starts, shaped like a mix.
  smart,

  /// Automix like a DJ: bars aligned, the next track time-stretched to the current one's tempo, and kept in phase.
  beatMatched,
}

/// How one track hands over to the next. Times are positions in each track.
class TransitionPlan {
  const TransitionPlan({
    required this.outStart,
    required this.outEnd,
    this.inCue = Duration.zero,
    this.speed = 1.0,
    this.style = TransitionStyle.crossfade,
    this.outBeats = const [],
    this.inBeats = const [],
    this.outAnchor = 0,
    this.inAnchor = 0,
  });

  /// A transition of [fade] that ends where the outgoing track does.
  factory TransitionPlan.ending(
    Duration trackDuration,
    Duration fade, {
    TransitionStyle style = TransitionStyle.crossfade,
  }) => TransitionPlan(outStart: trackDuration - fade, outEnd: trackDuration, style: style);

  /// Where in the outgoing track the next one comes in, and where the outgoing one is gone.
  final Duration outStart;
  final Duration outEnd;

  /// Where the next track starts playing (past any silence, on its first bar when beat matched).
  final Duration inCue;

  /// The next track's playback rate during the mix (time-stretched, pitch kept); back to normal afterwards.
  final double speed;

  final TransitionStyle style;

  /// Beat grids (seconds in each track) and the beat index of [outStart] and [inCue] in them, for keeping the two
  /// tracks in phase while they play together.
  final List<double> outBeats;
  final List<double> inBeats;
  final int outAnchor;
  final int inAnchor;

  Duration get duration => outEnd - outStart;

  bool get beatMatched => style == TransitionStyle.beatMatched;

  bool get isAutomix => style != TransitionStyle.crossfade;

  // Equal-power curves (sin/cos): summed loudness stays even, where linear ones dip by ~3 dB in the middle. Automix
  // brings the next track in sooner and lets the current one go later, so both play fully together for a moment, as
  // in a DJ mix.
  double fadeIn(double t) {
    final x = isAutomix ? (t / 0.75).clamp(0.0, 1.0) : t.clamp(0.0, 1.0);
    return sin(x * pi / 2);
  }

  double fadeOut(double t) {
    final x = isAutomix ? ((t - 0.25) / 0.75).clamp(0.0, 1.0) : t.clamp(0.0, 1.0);
    return cos(x * pi / 2);
  }

  TransitionPlan copyWith({Duration? outStart, Duration? outEnd, Duration? inCue}) => TransitionPlan(
    outStart: outStart ?? this.outStart,
    outEnd: outEnd ?? this.outEnd,
    inCue: inCue ?? this.inCue,
    speed: speed,
    style: style,
    outBeats: outBeats,
    inBeats: inBeats,
    outAnchor: outAnchor,
    inAnchor: inAnchor,
  );

  @override
  String toString() =>
      "TransitionPlan(${style.name}, out ${_s(outStart)}–${_s(outEnd)}, in at ${_s(inCue)}"
      "${speed != 1 ? ", speed ${speed.toStringAsFixed(3)}" : ""})";

  static String _s(Duration d) => (d.inMilliseconds / 1000).toStringAsFixed(2);
}

class AutomixPlanner {
  static const _defaultAutomixSeconds = 6;
  static const _minAutomixSeconds = 3.0;
  static const _minTrackForAutomix = Duration(seconds: 45);
  static const _noMixGenres = ["audiobook", "podcast", "speech", "classical"];

  /// How far apart two tempos can be and still be matched by time-stretching (Apple Music stays within a few %).
  static const maxTempoChange = 0.08;

  /// The longest stretch of silence at the start of the next track that is skipped.
  static const _maxSkippedIntro = 12.0;

  /// The first plan, from metadata alone. Null when the tracks should simply follow each other (gaplessly).
  static TransitionPlan? plan({
    required FinampQueueItem? current,
    required FinampQueueItem? next,
    required Duration currentDuration,
    required int crossfadeSeconds,
    required bool automix,
  }) {
    if (current == null || next == null) return null;
    final nextDuration = next.item.duration ?? next.baseItem.runTimeTicksDuration();
    final shortest = nextDuration == null || nextDuration > currentDuration ? currentDuration : nextDuration;

    if (!automix) {
      if (crossfadeSeconds <= 0) return null;
      final fade = Duration(seconds: crossfadeSeconds);
      if (shortest < fade * 2) return null;
      return TransitionPlan.ending(currentDuration, fade);
    }

    final from = current.baseItem;
    final to = next.baseItem;
    // An album's consecutive tracks often run into each other (live albums, DJ mixes, concept albums): keep them
    // gapless, as Apple Music does.
    if (isContinuation(from, to)) return null;
    if (_isNoMix(from) || _isNoMix(to)) return null;
    if (shortest < _minTrackForAutomix) return null;

    // Roughly 5% of the shorter track, between 3 s and the user's crossfade length (6 s when that is off).
    final maxSeconds = max(
      _minAutomixSeconds,
      (crossfadeSeconds > 0 ? crossfadeSeconds : _defaultAutomixSeconds) * 1.0,
    );
    final seconds = (shortest.inMilliseconds / 1000 * 0.05).clamp(_minAutomixSeconds, maxSeconds);
    return TransitionPlan.ending(
      currentDuration,
      Duration(milliseconds: (seconds * 1000).round()),
      style: TransitionStyle.smart,
    );
  }

  /// Improves an Automix plan with what the audio itself says: the end of the outgoing track ([outTail]) and the
  /// start of the next one ([inHead]). Beat matches when both have a clear beat at compatible tempos; otherwise
  /// at least skips the silence at either end.
  static TransitionPlan refine(
    TransitionPlan basic, {
    required Duration currentDuration,
    BeatAnalysis? outTail,
    BeatAnalysis? inHead,
  }) {
    if (!basic.isAutomix) return basic;
    final trackEnd = currentDuration.inMilliseconds / 1000;

    // Where the next track's music starts, if there is silence first.
    final inMusic = inHead?.musicStart;
    final cue = inMusic != null && inMusic > 0.15 && inMusic < _maxSkippedIntro ? inMusic : 0.0;

    if (outTail != null && inHead != null && outTail.hasTempo && inHead.hasTempo) {
      final matched = _beatMatch(outTail, inHead, cueFrom: cue, trackEnd: trackEnd);
      if (matched != null) return matched;
    }

    // No beat match: still mix where the music ends, not into the silence after it.
    final musicEnd = outTail?.musicEnd;
    var end = trackEnd;
    if (musicEnd != null && musicEnd > outTail!.windowStart + 5 && musicEnd < trackEnd - 0.5) {
      end = min(trackEnd, musicEnd + 0.3);
    }
    final length = basic.duration.inMilliseconds / 1000;
    final start = max(0.0, end - length);
    return TransitionPlan(outStart: _d(start), outEnd: _d(end), inCue: _d(cue), style: TransitionStyle.smart);
  }

  static TransitionPlan? _beatMatch(
    BeatAnalysis out,
    BeatAnalysis inn, {
    required double cueFrom,
    required double trackEnd,
  }) {
    // Tempo, allowing for one track being read at half or double the other's (86 vs 172 BPM is the same feel).
    var factor = 1.0;
    var ratio = out.bpm / inn.bpm;
    for (final f in const [2.0, 0.5]) {
      final r = out.bpm / (inn.bpm * f);
      if ((r - 1).abs() < (ratio - 1).abs()) {
        factor = f;
        ratio = r;
      }
    }
    if ((ratio - 1).abs() > maxTempoChange) return null;

    // Incoming: from its first bar once the music has started.
    final cue = inn.downbeats.firstWhere((d) => d >= cueFrom - 0.05, orElse: () => -1);
    if (cue < 0) return null;
    final inBeats = _scaleGrid(inn.beats, factor, keep: _nearestIndex(inn.beats, cue));
    if (inBeats.length < 8) return null;

    // End the mix on the last bar before the outgoing music stops.
    final musicEnd = min(out.musicEnd ?? trackEnd, trackEnd);
    final bars = out.downbeats.where((d) => d <= musicEnd + 0.05 && d < trackEnd - 0.2).toList();
    if (bars.length < 3) return null;
    final endBeat = out.beats.indexOf(bars.last);
    if (endBeat < 0) return null;

    final cueBeat = _nearestIndex(inBeats, cue);
    final inBeatsAvailable = inBeats.length - 1 - cueBeat;

    // As long a mix as both sides allow: 32 beats (8 bars), else 16, else 8.
    int? mixBeats;
    for (final candidate in const [32, 16, 8]) {
      if (endBeat - candidate >= 0 && inBeatsAvailable >= candidate) {
        mixBeats = candidate;
        break;
      }
    }
    if (mixBeats == null) return null;
    final startBeat = endBeat - mixBeats;
    final outStart = out.beats[startBeat];
    final outEnd = out.beats[endBeat];
    if (outEnd - outStart > 30) return null; // too slow to mix bar-wise in the window we have

    return TransitionPlan(
      outStart: _d(outStart),
      outEnd: _d(outEnd),
      inCue: _d(inBeats[cueBeat]),
      speed: ratio,
      style: TransitionStyle.beatMatched,
      outBeats: out.beats,
      inBeats: inBeats,
      outAnchor: startBeat,
      inAnchor: cueBeat,
    );
  }

  /// A beat grid at [factor] times its tempo: 2 adds a beat between each pair, 0.5 keeps every other one (those in
  /// step with beat [keep]).
  static List<double> _scaleGrid(List<double> beats, double factor, {int keep = 0}) {
    if (factor == 1.0) return beats;
    if (factor == 2.0) {
      return [
        for (var i = 0; i < beats.length; i++) ...[beats[i], if (i + 1 < beats.length) (beats[i] + beats[i + 1]) / 2],
      ];
    }
    return [for (var i = keep % 2; i < beats.length; i += 2) beats[i]];
  }

  static int _nearestIndex(List<double> list, double value) {
    var best = 0;
    for (var i = 1; i < list.length; i++) {
      if ((list[i] - value).abs() < (list[best] - value).abs()) best = i;
    }
    return best;
  }

  static Duration _d(double seconds) => Duration(microseconds: (seconds * 1e6).round());

  static bool isContinuation(BaseItemDto from, BaseItemDto to) {
    if (from.albumId == null || from.albumId != to.albumId) return false;
    final fromTrack = from.indexNumber;
    final toTrack = to.indexNumber;
    if (fromTrack == null || toTrack == null) return false;
    final fromDisc = from.parentIndexNumber ?? 1;
    final toDisc = to.parentIndexNumber ?? 1;
    if (fromDisc == toDisc) return toTrack == fromTrack + 1;
    return toDisc == fromDisc + 1 && toTrack == 1;
  }

  static bool _isNoMix(BaseItemDto item) =>
      item.genres?.any((genre) => _noMixGenres.contains(genre.toLowerCase())) ?? false;
}

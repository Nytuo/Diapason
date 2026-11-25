import 'dart:async';

import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/lyrics/furigana.dart';
import 'package:diapason/services/lyrics/japanese_dictionary.dart';
import 'package:diapason/services/lyrics/lyrics_translation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

final _log = Logger("LyricsExtras");

/// What is drawn around one lyric line besides its text.
@immutable
class LyricLineExtras {
  const LyricLineExtras({this.ruby = const [], this.romaji, this.translation});

  final List<RubySegment> ruby;
  final String? romaji;
  final String? translation;

  static const empty = LyricLineExtras();
}

/// Furigana, romaji and translation for a set of lines, by line index.
@immutable
class LyricsExtras {
  const LyricsExtras({this.furigana, this.translation});

  final List<FuriganaLine>? furigana;
  final LyricsTranslation? translation;

  static const none = LyricsExtras();

  LyricLineExtras operator [](int index) {
    final f = furigana != null && index < furigana!.length ? furigana![index] : null;
    final t = translation?[index];
    if (f == null && t == null) return LyricLineExtras.empty;
    return LyricLineExtras(ruby: f?.ruby ?? const [], romaji: f?.romaji, translation: t);
  }
}

/// The Japanese dictionary's download state, for widgets.
class JapaneseDictionaryNotifier extends Notifier<JapaneseDictionaryState> {
  @override
  JapaneseDictionaryState build() {
    final dictionary = JapaneseDictionary.instance;
    void listener() => state = dictionary.state.value;
    dictionary.state.addListener(listener);
    ref.onDispose(() => dictionary.state.removeListener(listener));
    unawaited(dictionary.refresh());
    return dictionary.state.value;
  }
}

final japaneseDictionaryProvider = NotifierProvider<JapaneseDictionaryNotifier, JapaneseDictionaryState>(
  JapaneseDictionaryNotifier.new,
);

/// Readings and romaji for a song's lines, when the settings ask for them, the song is Japanese and the dictionary is
/// installed. Null otherwise.
final furiganaProvider = FutureProvider.autoDispose.family<List<FuriganaLine>?, List<LyricLine>>((ref, lines) async {
  final furigana = ref.watch(finampSettingsProvider.lyricsFurigana);
  final romaji = ref.watch(finampSettingsProvider.lyricsRomaji);
  if (!furigana && !romaji) return null;
  final texts = [for (final l in lines) l.text ?? ""];
  if (!Furigana.isJapaneseSong(texts)) return null;
  if (ref.watch(japaneseDictionaryProvider.select((s) => s.status)) != JapaneseDictionaryStatus.ready) return null;
  final annotated = await JapaneseDictionary.instance.annotate(texts);
  return [
    for (final line in annotated)
      FuriganaLine(ruby: furigana ? line.ruby : const [], romaji: romaji ? line.romaji : null),
  ];
});

/// Bumps whenever the translation box changes (config, per-song choices, cache), so dependents re-read it.
class LyricsTranslationRevision extends Notifier<int> {
  @override
  int build() {
    final listenable = LyricsTranslationService.instance.listenable();
    if (listenable != null) {
      void listener() => state++;
      listenable.addListener(listener);
      ref.onDispose(() => listenable.removeListener(listener));
    }
    return 0;
  }
}

final lyricsTranslationRevisionProvider = NotifierProvider<LyricsTranslationRevision, int>(
  LyricsTranslationRevision.new,
);

final lyricsTranslationConfigProvider = Provider<LyricsTranslationConfig>((ref) {
  ref.watch(lyricsTranslationRevisionProvider);
  return LyricsTranslationService.instance.config;
});

/// Whether the user turned translation off for this track.
final lyricsTranslationHiddenProvider = Provider.family<bool, String>((ref, trackId) {
  ref.watch(lyricsTranslationRevisionProvider);
  return LyricsTranslationService.instance.isHidden(trackId);
});

/// The language lyrics are translated into: the one set in the settings, else the app's.
String lyricsTranslationTarget(BuildContext context, LyricsTranslationConfig config) =>
    config.targetLanguage.isNotEmpty ? config.targetLanguage : Localizations.localeOf(context).toLanguageTag();

typedef LyricsTranslationRequest = ({String trackId, List<LyricLine> lines, String target});

/// The translation of a track's lyrics, when translation is on and not hidden for the track. Errors are reported and
/// rethrown, so the lyrics options can show them.
final lyricsTranslationProvider = FutureProvider.autoDispose.family<LyricsTranslation?, LyricsTranslationRequest>((
  ref,
  request,
) async {
  if (!ref.watch(finampSettingsProvider.lyricsTranslationEnabled)) return null;
  if (ref.watch(lyricsTranslationHiddenProvider(request.trackId))) return null;
  final config = ref.watch(lyricsTranslationConfigProvider);
  if (!config.isUsable) return null;
  try {
    return await LyricsTranslationService.instance.translate(
      trackId: request.trackId,
      lines: [for (final l in request.lines) l.text],
      target: request.target,
      config: config,
    );
  } catch (e, stack) {
    FriendlyError.report(_log, "Lyrics translation", e, stack);
    rethrow;
  }
});

/// Message for a translation error, for the lyrics options.
String lyricsTranslationErrorMessage(Object error) =>
    error is LyricsTranslationException ? error.message : FriendlyError.message(error);

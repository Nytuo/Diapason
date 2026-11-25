import 'package:diapason/services/radio/icy_metadata.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rxdart/rxdart.dart';

/// What the live station currently playing says is on air (from its ICY
/// `StreamTitle`), or null when nothing live is playing or the station sends
/// no metadata. Fed by the audio handler.
class RadioNowPlaying {
  RadioNowPlaying._();

  static final _subject = BehaviorSubject<IcyNowPlaying?>.seeded(null);

  static IcyNowPlaying? get current => _subject.value;

  static Stream<IcyNowPlaying?> get stream => _subject.stream.distinct();

  static void set(IcyNowPlaying? value) {
    if (_subject.value != value) _subject.add(value);
  }
}

final radioNowPlayingProvider = StreamProvider<IcyNowPlaying?>((ref) => RadioNowPlaying.stream);

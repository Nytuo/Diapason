import 'package:diapason/services/tvos/appletv_audio_channel.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// Whether this build opens the Isar database.
///
/// Isar's native core has no tvOS binary and no web implementation, so tvOS
/// and the browser never open it and never register an Isar singleton. They
/// keep the current user and media source configs in Hive instead (see
/// [FinampUserHelper] and [MediaSourceService]); downloads, playback stats,
/// pinned shortcuts and search history are Isar-only and unavailable there.
bool get isarAvailable => !kIsWeb && !AppleTvAudioChannel.isSupported;

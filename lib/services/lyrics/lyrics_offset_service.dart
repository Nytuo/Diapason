import 'package:diapason/models/jellyfin_models.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

/// Per-track timing correction for synced lyrics, for files whose lyrics run a little ahead of or behind the music.
///
/// The offset is in milliseconds and positive means "show the lyrics later": a line timed at 1:00.0 with a +500 ms
/// offset lights up at 1:00.5. Kept per track id, so it survives restarts and is part of backups.
class LyricsOffsetService {
  LyricsOffsetService._();

  static const boxName = "LyricsOffsets";

  /// One nudge of the offset buttons.
  static const step = 500;

  /// Far enough for any real mis-sync; stops runaway tapping.
  static const limit = 30000;

  static Box<int>? _testBox;

  @visibleForTesting
  static set testBox(Box<int>? box) => _testBox = box;

  static Box<int>? get _box => _testBox ?? (Hive.isBoxOpen(boxName) ? Hive.box<int>(boxName) : null);

  static Future<void> open() async {
    if (!Hive.isBoxOpen(boxName)) await Hive.openBox<int>(boxName);
  }

  static int offsetMs(BaseItemId? id) => id == null ? 0 : (_box?.get(id.raw) ?? 0);

  static Future<void> setOffset(BaseItemId id, int offsetMs) async {
    final box = _box;
    if (box == null) return;
    final clamped = offsetMs.clamp(-limit, limit);
    if (clamped == 0) {
      await box.delete(id.raw);
    } else {
      await box.put(id.raw, clamped);
    }
  }

  static Future<void> nudge(BaseItemId id, int deltaMs) => setOffset(id, offsetMs(id) + deltaMs);

  static Future<void> reset(BaseItemId id) => setOffset(id, 0);

  /// Rebuilds when this track's offset changes. Null when storage isn't available (then the offset is always 0).
  static ValueListenable<Box<int>>? listenable(BaseItemId id) => _box?.listenable(keys: [id.raw]);

  /// Every stored offset, for backups.
  static Map<String, int> all() => {for (final key in _box?.keys ?? const <dynamic>[]) "$key": ?_box!.get(key)};

  static Future<void> restore(Map<String, int> offsets) async {
    final box = _box;
    if (box == null) return;
    await box.putAll({
      for (final entry in offsets.entries)
        if (entry.value != 0) entry.key: entry.value.clamp(-limit, limit),
    });
  }

  /// "+0.5 s", "−1.0 s", "0.0 s".
  static String format(int offsetMs) {
    final seconds = (offsetMs.abs() / 1000).toStringAsFixed(1);
    if (offsetMs > 0) return "+$seconds s";
    if (offsetMs < 0) return "−$seconds s";
    return "$seconds s";
  }
}

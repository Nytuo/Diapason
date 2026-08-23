import 'package:diapason/models/jellyfin_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:rxdart/rxdart.dart';

/// Local, per-device blocklist of items the user has chosen to hide from
/// browse/home views ("Not Interested"). Hiding is soft: hidden items are
/// filtered out of browse queries at the [AggregateBackend] layer, but are
/// still returned by search so the user can find them again on purpose.
class HiddenItemsService {
  static const boxName = "HiddenItems";

  static Box<bool> get _box => Hive.box<bool>(boxName);

  static bool isHidden(BaseItemId id) => _box.get(id.raw) ?? false;

  static Future<void> hide(BaseItemId id) => _box.put(id.raw, true);

  static Future<void> unhide(BaseItemId id) => _box.delete(id.raw);

  static Set<String> get hiddenIds => _box.keys.cast<String>().toSet();
}

/// Reactive view of [HiddenItemsService.hiddenIds] for use in widgets/providers.
final hiddenItemIdsProvider = StreamProvider<Set<String>>((ref) {
  final box = Hive.box<bool>(HiddenItemsService.boxName);
  return box.watch().map((_) => HiddenItemsService.hiddenIds).startWith(HiddenItemsService.hiddenIds);
});

import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Apple TV only lets an app write to its Caches and tmp folders: Documents and Application Support fail with
/// "operation not permitted" on a real device (the simulator allows them). Everything the app persists goes through
/// those two, so on tvOS they are pointed at a folder inside Caches. tvOS may purge Caches when storage is low;
/// that is the platform's limit for apps without iCloud.
class TvOSPathProvider extends PathProviderPlatform {
  TvOSPathProvider(this._inner);

  static void install() {
    final current = PathProviderPlatform.instance;
    if (current is! TvOSPathProvider) {
      PathProviderPlatform.instance = TvOSPathProvider(current);
    }
  }

  final PathProviderPlatform _inner;

  Future<String?> _data(String name) async {
    final cache = await _inner.getApplicationCachePath();
    if (cache == null) return null;
    final dir = Directory('$cache/$name');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  @override
  Future<String?> getApplicationDocumentsPath() => _data('Documents');

  @override
  Future<String?> getApplicationSupportPath() => _data('Support');

  @override
  Future<String?> getLibraryPath() => _data('Library');

  @override
  Future<String?> getApplicationCachePath() => _inner.getApplicationCachePath();

  @override
  Future<String?> getTemporaryPath() => _inner.getTemporaryPath();
}

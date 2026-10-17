import 'dart:io';

import 'package:diapason/hive_registrar.g.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/locale_adapter.dart';
import 'package:diapason/models/migration_adapters.dart';
import 'package:diapason/models/theme_mode_adapter.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// path_provider pointing every directory at a folder the test owns.
class FakePathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  FakePathProvider(this.root);

  final String root;

  Future<String> _dir(String name) async => (await Directory('$root/$name').create(recursive: true)).path;

  @override
  Future<String?> getApplicationSupportPath() => _dir('support');
  @override
  Future<String?> getApplicationDocumentsPath() => _dir('documents');
  @override
  Future<String?> getTemporaryPath() => _dir('tmp');
  @override
  Future<String?> getApplicationCachePath() => _dir('cache');
  @override
  Future<String?> getDownloadsPath() => _dir('downloads');
}

/// A scratch directory with fake path_provider, removed again by [dispose].
class TestEnv {
  TestEnv._(this.dir);

  static bool _adaptersRegistered = false;

  final Directory dir;

  static Future<TestEnv> create() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // The test binding answers every HttpClient request with 400; tests that talk to a real local
    // server (loopback) need the genuine client.
    HttpOverrides.global = null;
    final dir = await Directory.systemTemp.createTemp('diapason_test_');
    PathProviderPlatform.instance = FakePathProvider(dir.path);
    return TestEnv._(dir);
  }

  /// Opens the same Hive boxes the app opens at startup, in this test's folder.
  /// Pass [settings] to also create the default [FinampSettings].
  Future<void> openHive({bool settings = true}) async {
    Hive.init(dir.path);
    // Adapters live in a process-wide registry; registering twice throws.
    if (!_adaptersRegistered) {
      Hive.registerAdapters();
      Hive.registerAdapter(ThemeModeAdapter());
      Hive.registerAdapter(ColorAdapter());
      Hive.registerAdapter(LocaleAdapter());
      Hive.registerAdapter(FinampStorableQueueInfoMigrationAdapter());
      _adaptersRegistered = true;
    }
    await Hive.openBox<bool>('HiddenItems');
    if (settings) {
      final box = await Hive.openBox<FinampSettings>('FinampSettings');
      await box.put('FinampSettings', await FinampSettings.create());
    }
  }

  /// Changes stored settings the way the app's setters do.
  void updateSettings(void Function(FinampSettings s) change) {
    final s = FinampSettingsHelper.finampSettings;
    change(s);
    FinampSettingsHelper.overwriteFinampSettings(s);
  }

  Future<void> dispose() async {
    await Hive.close();
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}

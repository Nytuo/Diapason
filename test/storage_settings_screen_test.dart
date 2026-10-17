import 'dart:io';

import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/screens/storage_settings_screen.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/stream_cache_service.dart';
import 'package:diapason/services/youtube/ytdlp_paths.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'support/test_env.dart';

class _FakeStreamCache implements StreamCacheService {
  int bytes = 5 * 1024 * 1024;
  int cleared = 0;

  @override
  Future<int> currentSizeBytes() async => bytes;

  @override
  Future<void> clear() async {
    cleared++;
    bytes = 0;
  }

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Settings → Storage & logs: what the app keeps, how to free it, and how chatty the log is.
void main() {
  late TestEnv env;
  late _FakeStreamCache cache;
  var coverCleared = 0;
  final rootLevel = Logger.root.level;

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(finampSettingsProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routes: {'/logs': (_) => const Scaffold(body: Text('logs page'))},
          home: StorageSettingsScreen(coverArtBytes: () async => 2048, clearCoverArt: () async => coverCleared++),
        ),
      ),
    );
    // Sizes are measured with real file I/O: let it finish, then let the widgets see the answers.
    // Each file touched needs a turn of the real event loop followed by a turn of the test's fake one.
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
  }

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
    cache = _FakeStreamCache();
    coverCleared = 0;
    GetIt.instance.registerSingleton<StreamCacheService>(cache);
    YtDlpPaths.execBlockedReason = null;
  });

  tearDown(() async {
    Logger.root.level = rootLevel;
    await GetIt.instance.reset();
    await env.dispose();
  });

  testWidgets('lists what the app keeps, with sizes', (tester) async {
    await open(tester);

    expect(find.text('Streamed tracks'), findsOneWidget);
    expect(find.text('Cover art'), findsOneWidget);
    expect(find.text('Log files'), findsOneWidget);
    expect(find.textContaining('5'), findsWidgets, reason: 'the 5 MB stream cache is reported');
  });

  testWidgets('clearing the stream cache empties it and says so', (tester) async {
    await open(tester);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, 'Clear').first);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(cache.cleared, 1);
    expect(find.text('Streamed track cache cleared'), findsOneWidget);
  });

  testWidgets('clearing cover art clears only the cover art', (tester) async {
    await open(tester);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, 'Clear').at(1));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(coverCleared, 1);
    expect(cache.cleared, 0);
    expect(find.text('Cover art cache cleared'), findsOneWidget);
  });

  testWidgets('"Delete old" removes only the rotated log, never the one being written', (tester) async {
    final support = Directory(p.join(env.dir.path, 'support'))..createSync(recursive: true);
    final current = File(p.join(support.path, 'diapason-logs.txt'))..writeAsStringSync('current log');
    final old = File(p.join(support.path, 'diapason-logs-old.txt'))..writeAsStringSync('old log, quite long');
    await open(tester);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, 'Delete old'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    expect(old.existsSync(), isFalse);
    expect(current.existsSync(), isTrue);
    expect(current.readAsStringSync(), 'current log');
  });

  testWidgets('choosing how much detail to log takes effect immediately and is remembered', (tester) async {
    await open(tester);
    expect(find.textContaining('Most detail'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('Problems only'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(FinampSettingsHelper.finampSettings.logLevel, 'warning');
    expect(Logger.root.level, Level.WARNING);
    expect(find.textContaining('Only warnings and errors'), findsOneWidget);
  });

  testWidgets('can jump to the log viewer', (tester) async {
    await open(tester);

    await tester.ensureVisible(find.text('View and share logs'));
    await tester.tap(find.text('View and share logs'));
    await tester.pumpAndSettle();

    expect(find.text('logs page'), findsOneWidget);
  });
}

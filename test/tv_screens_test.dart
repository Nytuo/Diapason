import 'package:diapason/models/media_source.dart';
import 'package:diapason/models/tv_profile.dart';
import 'package:diapason/screens/tv/tv_connect_screen.dart';
import 'package:diapason/screens/tv/tv_profile_edit_screen.dart';
import 'package:diapason/screens/tv/tv_profile_picker_screen.dart';
import 'package:diapason/screens/tv/tv_widgets.dart';
import 'package:diapason/services/connect/connect_mdns.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:diapason/services/connect/connect_player_bridge.dart';
import 'package:diapason/services/connect/connect_service.dart';
import 'package:diapason/services/tv/tv_profile_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'support/test_env.dart';

class MemoryTvProfiles implements TvProfileStore {
  final Map<String, String> values = {};

  @override
  Iterable<String> get keys => values.keys;

  @override
  String? get(String key) => values[key];

  @override
  Future<void> put(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Sources implements TvProfileSources {
  @override
  final List<MediaSourceConfig> sources = [
    MediaSourceConfig(sourceId: 'a', kind: MediaSourceKind.subsonic, name: 'My Navidrome'),
  ];

  @override
  Future<void> setEnabled(MediaSourceConfig config, bool enabled) async => config.enabled = enabled;
}

class _FakeMdns implements ConnectMdns {
  void Function(List<MdnsService>)? onChanged;
  final registered = <Map<String, Object?>>[];
  bool browsing = false;

  @override
  Future<void> register({
    required String name,
    required String type,
    required int port,
    required Map<String, String> txt,
  }) async => registered.add({'name': name, 'type': type, 'port': port, 'txt': txt});

  @override
  Future<void> unregister() async {}

  @override
  Future<void> startBrowse(String type, void Function(List<MdnsService> services) onChanged) async {
    browsing = true;
    this.onChanged = onChanged;
  }

  @override
  Future<void> stopBrowse() async => browsing = false;
}

/// Taps something whose handler writes to Hive (real file I/O), which needs real time rather than the test clock.
/// A few frames: pumpAndSettle never returns while a text field's caret is blinking.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<T> real<T>(WidgetTester tester, Future<T> Function() body) async => (await tester.runAsync(body)) as T;

Future<void> tapReal(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await settle(tester); // routes and dialogs finish closing on the test clock...
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300))); // ...file writes on real time
  await settle(tester);
}

void main() {
  late TestEnv env;
  late TvProfileService profiles;
  final visited = <String>[];

  Widget app(Widget home) => MaterialApp(
    home: home,
    onGenerateRoute: (settings) {
      visited.add('${settings.name}${settings.arguments == null ? '' : ':${settings.arguments}'}');
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => Scaffold(body: Text('page ${settings.name}')),
      );
    },
  );

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
    visited.clear();
    profiles = TvProfileService(MemoryTvProfiles(), _Sources());
    GetIt.instance.registerSingleton<TvProfileService>(profiles);
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await env.dispose();
  });

  group('"Who\'s listening?"', () {
    testWidgets('lists the profiles with their accounts and offers to add one', (tester) async {
      await profiles.create('Alex', sourceIds: ['a']);
      await profiles.create('Sam');
      await tester.pumpWidget(app(const TvProfilePickerScreen()));

      expect(find.text("Who's listening?"), findsOneWidget);
      expect(find.text('Alex'), findsOneWidget);
      expect(find.text('1 account'), findsOneWidget);
      expect(find.text('0 accounts'), findsOneWidget);
      expect(find.text('Add profile'), findsOneWidget);
      expect(find.text('Manage profiles'), findsOneWidget);
    });

    testWidgets('choosing a profile makes it the active one and goes to the TV home', (tester) async {
      final alex = await profiles.create('Alex', sourceIds: ['a']);
      await tester.pumpWidget(app(const TvProfilePickerScreen()));

      await tester.tap(find.text('Alex'));

      expect(profiles.active?.id, alex.id);
      expect(visited, contains('/tv'));
    });

    testWidgets('"Add profile" asks for a name, creates the profile and takes them to add an account', (tester) async {
      await tester.pumpWidget(app(const TvProfilePickerScreen()));
      await tester.tap(find.text('Add profile'));
      await settle(tester);
      expect(find.text('New profile'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Maya');
      await tester.tap(find.text('Create'));

      expect(profiles.profiles.single.name, 'Maya');
      expect(profiles.active?.name, 'Maya');
      expect(visited.any((v) => v.contains('sources') || v.contains('Sources')), isTrue);
    });

    testWidgets('cancelling the new-profile dialog creates nothing', (tester) async {
      await tester.pumpWidget(app(const TvProfilePickerScreen()));
      await tester.tap(find.text('Add profile'));
      await settle(tester);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(profiles.profiles, isEmpty);
    });

    testWidgets('"Manage profiles" turns choosing into editing', (tester) async {
      final alex = await profiles.create('Alex');
      await tester.pumpWidget(app(const TvProfilePickerScreen()));

      await tester.tap(find.text('Manage profiles'));
      await tester.pump();
      expect(find.text('Manage profiles'), findsOneWidget, reason: 'the title');
      expect(find.text('Done'), findsOneWidget);

      await tester.tap(find.text('Alex'));
      expect(visited, contains('/tv/profiles/edit:${alex.id}'));
      expect(profiles.active, isNull, reason: 'editing does not switch to them');

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.tap(find.text('Done'));
      await tester.pump();
      expect(find.text("Who's listening?"), findsOneWidget);
    });

    testWidgets('no more than the limit can be added', (tester) async {
      for (var i = 0; i < 8; i++) {
        await profiles.create('P$i');
      }
      await tester.pumpWidget(app(const TvProfilePickerScreen()));
      expect(find.text('Add profile'), findsNothing);
    });
  });

  group('editing a profile', () {
    testWidgets('renaming, recolouring and listing accounts', (tester) async {
      final alex = await profiles.create('Alex', sourceIds: ['a']);
      await tester.pumpWidget(app(TvProfileEditScreen(profileId: alex.id)));

      expect(find.textContaining('My Navidrome'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Alexandra');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      expect(profiles.profiles.single.name, 'Alexandra');

      // The first avatar is the profile's own; the swatches follow, in the order of the default colours.
      await tester.tap(find.byType(TvAvatar).at(4));
      await settle(tester);
      expect(profiles.profiles.single.colorValue, TvProfile.defaultColors[3]);
    });

    testWidgets('a profile with no accounts says so, and adding one makes it the listening profile first', (
      tester,
    ) async {
      final sam = await profiles.create('Sam');
      await tester.pumpWidget(app(TvProfileEditScreen(profileId: sam.id)));
      expect(find.textContaining('No accounts yet'), findsOneWidget);

      await tester.tap(find.text('Add an account'));
      expect(profiles.active?.id, sam.id);
    });

    testWidgets('deleting asks first', (tester) async {
      final sam = await profiles.create('Sam');
      await tester.pumpWidget(app(TvProfileEditScreen(profileId: sam.id)));

      await tester.tap(find.text('Delete profile'));
      await settle(tester);
      expect(find.text('Delete Sam?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(profiles.profiles, hasLength(1));

      await tester.tap(find.text('Delete profile'));
      await settle(tester);
      await tester.tap(find.text('Delete'));
      expect(profiles.profiles, isEmpty);
    });

    testWidgets('a profile that no longer exists shows an empty page, not an error', (tester) async {
      await tester.pumpWidget(app(const TvProfileEditScreen(profileId: 'gone')));
      expect(find.byType(Scaffold), findsOneWidget);
    });
  });

  group('Diapason Connect on the TV', () {
    late _FakeMdns mdns;
    late ConnectService connect;

    setUp(() async {
      mdns = _FakeMdns();
      connect = ConnectService(mdns: mdns);
      GetIt.instance.registerSingleton<ConnectService>(connect);
      await connect.start(deviceName: 'Apple TV');
    });

    tearDown(() => connect.stop());

    testWidgets('the TV advertises itself so other devices can find and control it', (tester) async {
      expect(mdns.registered.single['name'], 'Apple TV');
      expect(mdns.registered.single['type'], '_diapason-connect._tcp');
      expect((mdns.registered.single['txt'] as Map)['token'], isNotEmpty);
    });

    testWidgets('it lists the devices found, picks one, and shows what it is playing', (tester) async {
      await tester.pumpWidget(app(const TvConnectScreen()));
      expect(find.textContaining('Looking for devices'), findsOneWidget);
      expect(mdns.browsing, isTrue);

      mdns.onChanged!([
        const MdnsService(name: "Maya's phone", host: '192.168.1.20', port: 4711, txt: {'token': 'abc'}),
        const MdnsService(name: 'No token', host: '192.168.1.21', port: 1, txt: {}),
      ]);
      await tester.pump();
      expect(find.text("Maya's phone"), findsOneWidget);
      expect(find.text('No token'), findsNothing, reason: 'a device with no token cannot be controlled');
      expect(find.text('192.168.1.20'), findsOneWidget);

      connect.connectedDevice.value = connect.devices.value.single;
      connect.remoteStatus.value = const ConnectStatus(
        song: ConnectSong(id: '1', title: 'Opening', artist: 'Alpha', album: 'First', duration: 100),
        state: 'playing',
        position: 25,
        volume: 0.5,
      );
      await tester.pump();
      expect(find.text("Playing on Maya's phone"), findsOneWidget);
      expect(find.text('Opening'), findsOneWidget);
      expect(find.text('Pause'), findsOneWidget);
      expect(find.text('Disconnect'), findsOneWidget);

      await tester.tap(find.text('Disconnect'));
      await tester.pump();
      expect(connect.connectedDevice.value, isNull);
    });

    testWidgets('leaving the screen stops looking', (tester) async {
      await tester.pumpWidget(app(const TvConnectScreen()));
      await tester.pumpWidget(const SizedBox());
      expect(mdns.browsing, isFalse);
    });
  });
}

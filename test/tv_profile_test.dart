import 'package:diapason/models/media_source.dart';
import 'package:diapason/models/tv_profile.dart';
import 'package:diapason/services/tv/tv_profile_service.dart';
import 'package:flutter_test/flutter_test.dart';

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
  _Sources(this.sources);

  @override
  final List<MediaSourceConfig> sources;
  final List<(String, bool)> changes = [];

  @override
  Future<void> setEnabled(MediaSourceConfig config, bool enabled) async {
    config.enabled = enabled;
    changes.add((config.sourceId, enabled));
  }
}

MediaSourceConfig _source(String id, {MediaSourceKind kind = MediaSourceKind.subsonic}) =>
    MediaSourceConfig(sourceId: id, kind: kind, name: id);

void main() {
  late TestEnv env;
  late _Sources sources;
  late TvProfileService service;

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();

    sources = _Sources([_source('a'), _source('b'), _source('c'), _source('yt', kind: MediaSourceKind.youtube)]);
    service = TvProfileService(MemoryTvProfiles(), sources);
  });

  tearDown(() => env.dispose());

  group('a profile', () {
    test('round-trips through JSON and compares by value', () {
      const p = TvProfile(id: 'x', name: 'Alex', colorValue: 0xFF112233, sourceIds: ['a', 'b']);
      expect(TvProfile.decode(p.encode()), p);
      expect(TvProfile.decode(p.encode()).hashCode, p.hashCode);
      expect(p.copyWith(name: 'Sam') == p, isFalse);
      expect(p.copyWith(sourceIds: ['a']) == p, isFalse);
    });

    test('has an initial, and sensible defaults for missing fields', () {
      expect(const TvProfile(id: 'x', name: ' alex ', colorValue: 1).initial, 'A');
      expect(const TvProfile(id: 'x', name: '  ', colorValue: 1).initial, '?');
      final bare = TvProfile.fromJson({'id': 'x'});
      expect(bare.name, 'Profile');
      expect(bare.colorValue, TvProfile.defaultColors.first);
      expect(bare.sourceIds, isEmpty);
    });
  });

  group('managing profiles', () {
    test('new profiles get different colours and an unnamed one is numbered', () async {
      final a = await service.create('Alex');
      final b = await service.create('  ');
      expect(a.colorValue, isNot(b.colorValue));
      expect(b.name, 'Profile 2');
      expect(service.profiles.map((p) => p.name), ['Alex', 'Profile 2']);
    });

    test('profiles are listed by name, ignoring case', () async {
      await service.create('sam');
      await service.create('Alex');
      await service.create('maya');
      expect(service.profiles.map((p) => p.name), ['Alex', 'maya', 'sam']);
    });

    test('rename and recolour; a blank name is ignored; unknown ids do nothing', () async {
      final p = await service.create('Alex');
      await service.rename(p.id, '  Alexandra ');
      expect(service.profiles.single.name, 'Alexandra');
      await service.rename(p.id, '   ');
      expect(service.profiles.single.name, 'Alexandra');
      await service.recolor(p.id, 0xFF000001);
      expect(service.profiles.single.colorValue, 0xFF000001);
      await service.rename('nope', 'x');
      await service.recolor('nope', 1);
      expect(service.profiles, hasLength(1));
    });

    test('there is a limit on how many profiles one TV holds', () async {
      for (var i = 0; i < 8; i++) {
        expect(service.canAddMore, isTrue);
        await service.create('P$i');
      }
      expect(service.canAddMore, isFalse);
    });

    test('deleting forgets the profile, and the active one stops being active', () async {
      final a = await service.create('Alex');
      await service.select(a.id);
      expect(service.active?.id, a.id);
      await service.delete(a.id);
      expect(service.profiles, isEmpty);
      expect(service.active, isNull);
      await service.delete('nope');
    });

    test('listeners hear every change', () async {
      var heard = 0;
      service.addListener(() => heard++);
      final p = await service.create('Alex');
      await service.rename(p.id, 'B');
      await service.select(p.id);
      await service.attachSource('a');
      await service.delete(p.id);
      expect(heard, greaterThanOrEqualTo(5));
    });
  });

  group('whose accounts are shown', () {
    test('choosing a profile turns its accounts on and everyone else\'s off; YouTube is left alone', () async {
      final alex = await service.create('Alex', sourceIds: ['a']);
      final sam = await service.create('Sam', sourceIds: ['b', 'c']);

      await service.select(alex.id);
      expect(sources.sources.where((s) => s.enabled).map((s) => s.sourceId), containsAll(['a', 'yt']));
      expect(sources.sources.firstWhere((s) => s.sourceId == 'b').enabled, isFalse);

      sources.changes.clear();
      await service.select(sam.id);
      expect(sources.sources.firstWhere((s) => s.sourceId == 'a').enabled, isFalse);
      expect(sources.sources.firstWhere((s) => s.sourceId == 'b').enabled, isTrue);
      expect(sources.changes.map((c) => c.$1), isNot(contains('yt')));
    });

    test('choosing the profile that is already showing changes nothing', () async {
      final alex = await service.create('Alex', sourceIds: ['a', 'b', 'c']);
      await service.select(alex.id);
      sources.changes.clear();
      await service.select(alex.id);
      expect(sources.changes, isEmpty);
    });

    test('a new account belongs to whoever is listening; an account that goes is removed everywhere', () async {
      final alex = await service.create('Alex', sourceIds: ['a']);
      final sam = await service.create('Sam', sourceIds: ['a', 'b']);
      await service.attachSource('c');
      expect(service.profiles.every((p) => !p.sourceIds.contains('c')), isTrue, reason: 'nobody is listening yet');

      await service.select(sam.id);
      await service.attachSource('c');
      await service.attachSource('c');
      expect(service.active!.sourceIds, ['a', 'b', 'c']);

      await service.detachSource('a');
      expect(service.profiles.firstWhere((p) => p.id == alex.id).sourceIds, isEmpty);
      expect(service.profiles.firstWhere((p) => p.id == sam.id).sourceIds, ['b', 'c']);
    });

    test('a profile can say which accounts it has', () async {
      final sam = await service.create('Sam', sourceIds: ['b', 'zzz']);
      expect(service.sourcesOf(sam).map((s) => s.sourceId), ['b']);
    });
  });

  group('first launch', () {
    test('accounts that already existed become the first profile and it is chosen', () async {
      await service.adoptExistingSources(name: 'Home');
      expect(service.profiles.single.name, 'Home');
      expect(service.profiles.single.sourceIds, ['a', 'b', 'c'], reason: 'YouTube is not an account');
      expect(service.active?.name, 'Home');
    });

    test('a fresh TV with no accounts gets no profile, and existing profiles are left alone', () async {
      final empty = TvProfileService(MemoryTvProfiles(), _Sources([]));
      await empty.adoptExistingSources();
      expect(empty.profiles, isEmpty);

      await service.create('Alex');
      await service.adoptExistingSources();
      expect(service.profiles, hasLength(1));
    });

    test('the demo profiles are only added when there are none', () async {
      await service.seedDemoProfiles();
      expect(service.profiles.map((p) => p.name), ['Alex', 'Maya', 'Sam']);
      await service.seedDemoProfiles();
      expect(service.profiles, hasLength(3));
    });
  });
}

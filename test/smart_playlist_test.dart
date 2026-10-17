import 'package:diapason/models/finamp_models.dart' show ArtistType;
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/smart_playlist.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/smart_playlist_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_ce/hive.dart';

import 'support/test_env.dart';

class _Library extends Fake implements AggregateBackend {
  _Library(this.tracks);
  final List<BaseItemDto> tracks;

  @override
  Future<List<BaseItemDto>> getItems({
    BaseItemDto? parentItem,
    BaseItemId? libraryFilter,
    String? includeItemTypes,
    String? sortBy,
    String? sortOrder,
    String? searchTerm,
    String? filters,
    BaseItemId? genreFilter,
    bool? isFavorite,
    ArtistType? artistType,
    int? startIndex,
    int? limit,
  }) async => tracks;
}

BaseItemDto _t(
  String id,
  String name, {
  String? album,
  String? artist,
  List<String>? genres,
  int? year,
  int plays = 0,
  bool fav = false,
}) => BaseItemDto(
  id: BaseItemId('s~$id'),
  name: name,
  type: 'Audio',
  album: album,
  albumArtist: artist,
  artists: artist == null ? null : [artist],
  genres: genres,
  productionYear: year,
  userData: UserItemDataDto(playbackPositionTicks: 0, playCount: plays, isFavorite: fav, played: false, key: id),
);

void main() {
  late TestEnv env;
  final tracks = [
    _t('1', 'Opening', album: 'First', artist: 'Alpha', genres: ['Rock'], year: 1999, plays: 10, fav: true),
    _t('2', 'closing', album: 'First', artist: 'Alpha', genres: ['Rock', 'Pop'], year: 2005, plays: 2),
    _t('3', 'Beta Song', album: 'Second', artist: 'Beta Band', genres: ['Folk'], year: 2012, plays: 7, fav: true),
    _t('4', 'Untitled'),
  ];

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
    await Hive.openBox<String>('SmartPlaylists');
    GetIt.instance.registerSingleton<AggregateBackend>(_Library(tracks));
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await env.dispose();
  });

  Future<List<String?>> run(SmartPlaylist p) async =>
      (await SmartPlaylistService.instance.resolve(p)).map((t) => t.name).toList();
  SmartPlaylist pl({
    bool all = true,
    List<SmartRule> rules = const [],
    SmartSort sort = SmartSort.title,
    bool desc = false,
    int? limit,
  }) => SmartPlaylist(id: 'x', name: 'x', matchAll: all, rules: rules, sort: sort, descending: desc, limit: limit);
  SmartRule r(SmartField f, SmartOp o, String v) => SmartRule(field: f, op: o, value: v);

  group('storage', () {
    test('playlists round-trip through JSON and a copy is independent', () {
      final original = pl(rules: [r(SmartField.title, SmartOp.contains, 'x')], limit: 5, desc: true);
      final copy = original.copy();
      copy.rules.first.value = 'changed';
      expect(original.rules.first.value, 'x');
      expect(SmartPlaylist.decode(original.encode()).limit, 5);
      expect(SmartPlaylist.decode(original.encode()).descending, isTrue);
      expect(SmartRule.fromJson({'field': 'year', 'op': 'equals'}).value, '');
      expect(SmartPlaylist.fromJson({'id': 'a'}).name, 'Smart Playlist');
      expect(SmartField.year.isNumeric, isTrue);
      expect(SmartField.favorite.isBool, isTrue);
      expect(SmartField.title.isNumeric, isFalse);
      expect(r(SmartField.album, SmartOp.equals, 'v').copy().field, SmartField.album);
    });

    test('save, get, list (sorted by name, case-insensitively) and delete', () async {
      final service = SmartPlaylistService.instance;
      await service.save(SmartPlaylist(id: 'b', name: 'beta'));
      await service.save(SmartPlaylist(id: 'a', name: 'Alpha'));
      expect((await service.list()).map((p) => p.name), ['Alpha', 'beta']);
      expect((await service.get('a'))!.name, 'Alpha');
      await service.delete('a');
      expect(await service.get('a'), isNull);
      expect(await service.list(), hasLength(1));
    });
  });

  group('rules', () {
    test('no rules means every track', () async => expect(await run(pl()), hasLength(4)));

    test('text: contains / is / is not / greater / less, ignoring case', () async {
      expect(await run(pl(rules: [r(SmartField.title, SmartOp.contains, 'OPEN')])), ['Opening']);
      expect(await run(pl(rules: [r(SmartField.title, SmartOp.equals, 'CLOSING')])), ['closing']);
      expect(await run(pl(rules: [r(SmartField.album, SmartOp.notEquals, 'first')])), ['Beta Song', 'Untitled']);
      expect(
        await run(pl(rules: [r(SmartField.artist, SmartOp.greaterThan, 'alpha')])),
        ['Beta Song', 'closing', 'Opening'],
        reason: 'the artist text is album artist + artists, so "alpha alpha" sorts after "alpha"',
      );
      expect(await run(pl(rules: [r(SmartField.artist, SmartOp.lessThan, 'b')])), ['closing', 'Opening', 'Untitled']);
      expect(await run(pl(rules: [r(SmartField.title, SmartOp.contains, '')])), hasLength(4));
    });

    test('genre matches any of a track\'s genres', () async {
      expect(await run(pl(rules: [r(SmartField.genre, SmartOp.contains, 'pop')])), ['closing']);
    });

    test('numbers: year and play count; garbage and missing values never match', () async {
      expect(await run(pl(rules: [r(SmartField.year, SmartOp.greaterThan, '2000')])), ['Beta Song', 'closing']);
      expect(await run(pl(rules: [r(SmartField.year, SmartOp.lessThan, '2000')])), ['Opening']);
      expect(await run(pl(rules: [r(SmartField.year, SmartOp.equals, '2005')])), ['closing']);
      expect(await run(pl(rules: [r(SmartField.year, SmartOp.contains, '2005')])), ['closing']);
      expect(await run(pl(rules: [r(SmartField.year, SmartOp.notEquals, '2005')])), ['Beta Song', 'Opening']);
      expect(await run(pl(rules: [r(SmartField.playCount, SmartOp.greaterThan, '5')])), ['Beta Song', 'Opening']);
      expect(await run(pl(rules: [r(SmartField.year, SmartOp.equals, 'abc')])), isEmpty);
    });

    test('favourite: yes/true, and "is not"', () async {
      expect(await run(pl(rules: [r(SmartField.favorite, SmartOp.equals, 'true')])), ['Beta Song', 'Opening']);
      expect(await run(pl(rules: [r(SmartField.favorite, SmartOp.equals, 'no')])), ['closing', 'Untitled']);
      expect(await run(pl(rules: [r(SmartField.favorite, SmartOp.notEquals, 'yes')])), ['closing', 'Untitled']);
    });

    test('match all vs match any', () async {
      final rules = [r(SmartField.artist, SmartOp.contains, 'alpha'), r(SmartField.favorite, SmartOp.equals, 'true')];
      expect(await run(pl(rules: rules)), ['Opening']);
      expect(await run(pl(all: false, rules: rules)), ['Beta Song', 'closing', 'Opening']);
    });
  });

  group('ordering and limit', () {
    test('by each field, ascending and descending', () async {
      expect(await run(pl(sort: SmartSort.title)), ['Beta Song', 'closing', 'Opening', 'Untitled']);
      expect(await run(pl(sort: SmartSort.title, desc: true)), ['Untitled', 'Opening', 'closing', 'Beta Song']);
      expect((await run(pl(sort: SmartSort.year))).first, 'Untitled');
      expect((await run(pl(sort: SmartSort.playCount, desc: true))).first, 'Opening');
      expect((await run(pl(sort: SmartSort.album))).first, 'Untitled');
      expect((await run(pl(sort: SmartSort.artist, desc: true))).first, 'Beta Song');
    });

    test('random keeps the same tracks; a limit cuts the list', () async {
      expect((await run(pl(sort: SmartSort.random))).toSet(), {'Opening', 'closing', 'Beta Song', 'Untitled'});
      expect(await run(pl(limit: 2)), hasLength(2));
      expect(await run(pl(limit: 50)), hasLength(4));
    });
  });
}

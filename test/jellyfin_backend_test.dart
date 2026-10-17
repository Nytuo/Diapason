import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/jellyfin_backend.dart';
import 'package:diapason/services/finamp_user_helper.dart';
import 'package:diapason/services/jellyfin_api_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

import 'support/test_env.dart';

class _FakeUsers extends Fake implements FinampUserHelper {
  @override
  String get authorizationHeader => 'MediaBrowser Token="tok"';
  @override
  String? get currentUserId => 'user-1';
  @override
  FinampUser? get currentUser => FinampUser(
    id: 'user-1',
    isLocal: false,
    publicAddress: 'http://x',
    localAddress: '',
    preferLocalNetwork: false,
    accessToken: 'tok',
    serverId: 's',
    views: {},
  );
}

/// Records what the backend asked the Jellyfin client for.
class _FakeApi extends Fake implements JellyfinApiHelper {
  final List<String> calls = [];
  List<BaseItemDto>? items = [];
  Object? failItems;
  Object? failLyrics;
  PlaybackProgressInfo? lastProgress;
  NewPlaylist? lastPlaylist;
  Uri downloadUri = Uri.parse('http://x/Items/1/Download');

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName;
    final named = invocation.namedArguments;
    String arg(String n) => '${named[Symbol(n)]}';
    if (name == #getItems) {
      calls.add('getItems(types=${arg('includeItemTypes')},search=${arg('searchTerm')},limit=${arg('limit')})');
      if (failItems != null) return Future<List<BaseItemDto>?>.error(failItems!);
      return Future<List<BaseItemDto>?>.value(items);
    }
    if (name == #getImageUrl) {
      return Uri.parse('http://x/img/${(named[#item] as BaseItemDto).name}?w=${arg('maxWidth')}');
    }
    return super.noSuchMethod(invocation);
  }

  @override
  Future<BaseItemDto?> getItemByIdBatched(BaseItemId itemId, [String? fields]) async {
    calls.add('byId(${itemId.raw})');
    return BaseItemDto(id: itemId, name: 'fetched', type: 'Audio');
  }

  @override
  Future<List<BaseItemDto>?> getInstantMix(BaseItemDto parentItem, {int? limit}) async {
    calls.add('mix(${parentItem.name},$limit)');
    return null;
  }

  @override
  Uri getTrackDownloadUrl({required BaseItemDto item, required DownloadProfile? transcodingProfile}) => downloadUri;

  @override
  Future<LyricDto> getLyrics({required BaseItemId itemId}) async {
    if (failLyrics != null) throw failLyrics!;
    return LyricDto();
  }

  @override
  Future<UserItemDataDto> addFavorite(BaseItemId itemId) async {
    calls.add('fav+(${itemId.raw})');
    return UserItemDataDto(playbackPositionTicks: 0, playCount: 0, isFavorite: true, played: false, key: '');
  }

  @override
  Future<UserItemDataDto> removeFavorite(BaseItemId itemId) async {
    calls.add('fav-(${itemId.raw})');
    return UserItemDataDto(playbackPositionTicks: 0, playCount: 0, isFavorite: false, played: false, key: '');
  }

  @override
  Future<NewPlaylistResponse> createNewPlaylist(NewPlaylist newPlaylist) async {
    lastPlaylist = newPlaylist;
    return NewPlaylistResponse(id: BaseItemId('pl1'));
  }

  @override
  Future<void> addItemstoPlaylist({required BaseItemId playlistId, List<BaseItemId>? ids}) async =>
      calls.add('add(${playlistId.raw},${ids!.length})');

  @override
  Future<void> removeItemsFromPlaylist({required BaseItemId playlistId, List<String>? entryIds}) async =>
      calls.add('remove(${playlistId.raw},${entryIds!.join(",")})');

  @override
  Future<void> updatePlaylist({required BaseItemId itemId, required NewPlaylist newPlaylist}) async {
    lastPlaylist = newPlaylist;
    calls.add('update(${itemId.raw})');
  }

  @override
  Future<void> reportPlaybackStart(PlaybackProgressInfo i) async {
    lastProgress = i;
    calls.add('start');
  }

  @override
  Future<void> updatePlaybackProgress(PlaybackProgressInfo i) async {
    lastProgress = i;
    calls.add('progress');
  }

  @override
  Future<void> stopPlaybackProgress(PlaybackProgressInfo i) async {
    lastProgress = i;
    calls.add('stop');
  }

  @override
  Future<void> logoutCurrentUser() async => calls.add('logout');
}

void main() {
  late TestEnv env;
  late _FakeApi api;
  late JellyfinBackend backend;
  late BaseItemDto track;

  JellyfinBackend make({String token = 'secret', String address = 'https://jf.example.com/base'}) => JellyfinBackend(
    MediaSourceConfig(
      sourceId: 'jf1',
      kind: MediaSourceKind.jellyfin,
      name: 'Home',
      publicAddress: address,
      accessToken: token,
    ),
  );

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
    api = _FakeApi();
    GetIt.instance
      ..registerSingleton<JellyfinApiHelper>(api)
      ..registerSingleton<FinampUserHelper>(_FakeUsers());
    backend = make();
    track = BaseItemDto(id: BaseItemId('jf1~abc'), name: 'Opening', type: 'Audio');
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await env.dispose();
  });

  test('connected means it holds an access token; capabilities advertise everything Jellyfin does', () {
    expect(backend.isConnected, isTrue);
    expect(make(token: '').isConnected, isFalse);
    expect(backend.sourceId, 'jf1');
    final c = backend.capabilities;
    expect([c.transcoding, c.playlists, c.favorites, c.instantMix, c.serverLyrics, c.search], everyElement(isTrue));
    expect(c.defaultTranscodingCodecs, contains(FinampTranscodingCodec.flac));
  });

  test('ping is true when a request works and false when it throws', () async {
    expect(await backend.ping(), isTrue);
    api.failItems = Exception('down');
    expect(await backend.ping(), isFalse);
  });

  test('getItems passes through; a null answer is an empty list', () async {
    api.items = null;
    expect(await backend.getItems(includeItemTypes: 'MusicAlbum', searchTerm: 'x', limit: 5), isEmpty);
    expect(api.calls.single, 'getItems(types=MusicAlbum,search=x,limit=5)');
    api.items = [track];
    expect(await backend.getItems(), [track]);
  });

  test('items by id, instant mixes and radio stations', () async {
    expect((await backend.getItemById(track.id))!.name, 'fetched');
    expect(await backend.getInstantMix(track, limit: 3), isEmpty);
    expect(await backend.getRadioStations(), isEmpty);
    expect(api.calls, ['byId(jf1~abc)', 'mix(Opening,3)']);
  });

  group('stream URLs', () {
    test('direct play points at the original file with the token, keeping the server base path', () async {
      final uri = (await backend.resolveStream(track, transcode: false)).uri;
      expect(uri.scheme, 'https');
      expect(uri.host, 'jf.example.com');
      expect(uri.path, '/base/Items/abc/File');
      expect(uri.queryParameters['ApiKey'], 'secret');
    });

    test('transcoding asks for HLS with the configured codec, bitrate and session', () async {
      final uri = (await backend.resolveStream(track, transcode: true, playSessionId: 'sess')).uri;
      expect(uri.path, '/base/Audio/abc/main.m3u8');
      expect(uri.queryParameters['audioCodec'], 'aac');
      expect(uri.queryParameters['segmentContainer'], 'mp4');
      expect(uri.queryParameters['playSessionId'], 'sess');
      expect(uri.queryParameters['audioSampleRate'], '44100');
      expect(uri.queryParameters['audioBitRate'], '${DefaultSettings.transcodeBitrate}');
      expect(uri.queryParameters['maxAudioChannels'], '2', reason: 'lossy output is downmixed by default');
    });

    test('lossless output has no bitrate, and is not downmixed unless the user asked for that', () async {
      env.updateSettings((s) => s.transcodingStreamingFormat = FinampTranscodingStreamingFormat.flacFragmentedMp4);
      var uri = (await backend.resolveStream(track, transcode: true)).uri;
      expect(uri.queryParameters.containsKey('audioBitRate'), isFalse);
      expect(uri.queryParameters.containsKey('maxAudioChannels'), isFalse);
      expect(uri.queryParameters['playSessionId'], '');

      env.updateSettings((s) => s.multichannelHandlingSetting = MultichannelHandlingSetting.stereoDownmixAll);
      uri = (await backend.resolveStream(track, transcode: true)).uri;
      expect(uri.queryParameters['maxAudioChannels'], '2');

      env.updateSettings((s) => s.multichannelHandlingSetting = MultichannelHandlingSetting.fixedBitrate);
      uri = (await backend.resolveStream(track, transcode: true)).uri;
      expect(uri.queryParameters.containsKey('maxAudioChannels'), isFalse);
    });

    test('downloads reuse the API URL and send the authorization header', () async {
      final source = await backend.resolveDownload(track);
      expect(source.uri, api.downloadUri);
      expect(source.headers['Authorization'], contains('tok'));
    });
  });

  test('images come from the API helper and need the authorization header', () {
    expect(backend.imageUrl(track, maxWidth: 200).toString(), 'http://x/img/Opening?w=200');
    expect(backend.imageHeaders['Authorization'], contains('tok'));
  });

  test('missing lyrics are null, never an error', () async {
    expect(await backend.getLyrics(track), isNotNull);
    api.failLyrics = Exception('404');
    expect(await backend.getLyrics(track), isNull);
  });

  test('favourites go to the matching endpoint', () async {
    await backend.setFavorite(track, isFavorite: true);
    await backend.setFavorite(track, isFavorite: false);
    expect(api.calls, ['fav+(jf1~abc)', 'fav-(jf1~abc)']);
  });

  test('playlists: create, add, remove, rename, reorder', () async {
    final playlist = await backend.createPlaylist('Mix', itemIds: [track.id], isPublic: false);
    expect(playlist.name, 'fetched');
    expect(api.lastPlaylist!.name, 'Mix');
    expect(api.lastPlaylist!.isPublic, isFalse);
    expect(api.lastPlaylist!.userId, 'user-1');

    await backend.addToPlaylist(playlist, [track.id, track.id]);
    await backend.removeFromPlaylist(playlist, ['e1', 'e2']);
    await backend.updatePlaylistMetadata(playlist, name: 'Renamed', isPublic: true);
    expect(api.lastPlaylist!.name, 'Renamed');
    await backend.reorderPlaylist(playlist, [track.id]);
    expect(api.lastPlaylist!.ids, [track.id]);
    expect(api.calls.where((c) => c.startsWith('add') || c.startsWith('remove') || c.startsWith('update')), [
      'add(pl1,2)',
      'remove(pl1,e1,e2)',
      'update(pl1)',
      'update(pl1)',
    ]);
  });

  test('playback reports use native ids and microsecond-based ticks', () async {
    await backend.reportPlaybackStart(track, playSessionId: 's');
    expect(api.lastProgress!.itemId.raw, 'abc');
    expect(api.lastProgress!.positionTicks, 0);
    expect(api.lastProgress!.playSessionId, 's');

    await backend.reportPlaybackProgress(track, position: const Duration(seconds: 2), isPaused: true);
    expect(api.lastProgress!.positionTicks, 20000000);
    expect(api.lastProgress!.isPaused, isTrue);

    await backend.reportPlaybackStopped(track, position: const Duration(seconds: 3));
    expect(api.lastProgress!.isPaused, isFalse);
    expect(api.calls, ['start', 'progress', 'stop']);
  });

  test('logging out ends the Jellyfin session', () async {
    await backend.logout();
    expect(api.calls, ['logout']);
  });
}

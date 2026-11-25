import 'dart:io';

import 'package:diapason/components/SourcesSettingsScreen/dlna_discovery_list.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/dlna_backend.dart';
import 'package:diapason/services/dlna/dlna_client.dart';
import 'package:diapason/services/dlna/dlna_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xml/xml.dart';

String fixture(String name) => File('test/fixtures/dlna/$name').readAsStringSync();

/// A `Browse`/`Search` answer carrying [didl], escaped the way servers send it.
String browseResponse(String didl, {int? returned, int? total, String action = 'Browse'}) {
  final count = returned ?? RegExp(r'<(item|container)\b').allMatches(didl).length;
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
      '<s:Body><u:${action}Response xmlns:u="$dlnaContentDirectoryService">'
      '<Result>${escapeXml(didl)}</Result>'
      '<NumberReturned>$count</NumberReturned><TotalMatches>${total ?? count}</TotalMatches>'
      '<UpdateID>1</UpdateID></u:${action}Response></s:Body></s:Envelope>';
}

String didl(String body) =>
    '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">$body</DIDL-Lite>';

String container(String id, String parent, String title, {String cls = 'object.container.storageFolder'}) =>
    '<container id="$id" parentID="$parent" restricted="1"><dc:title>$title</dc:title><upnp:class>$cls</upnp:class></container>';

String track(String id, String parent, String title, {String mime = 'audio/mpeg', String album = 'Great Album'}) =>
    '<item id="$id" parentID="$parent" restricted="1"><dc:title>$title</dc:title>'
    '<upnp:class>object.item.audioItem.musicTrack</upnp:class><upnp:artist>Main Artist</upnp:artist>'
    '<upnp:album>$album</upnp:album>'
    '<res duration="0:03:00" protocolInfo="http-get:*:$mime:*">http://192.168.1.10:8200/MediaItems/$id.mp3</res></item>';

/// A MiniDLNA-like server: no `Search`, a "Music" tree of views.
class FakeDlnaServer {
  FakeDlnaServer({this.searchCaps = ''});

  final String searchCaps;
  final requests = <({String action, Map<String, String> args})>[];

  /// Children by object id.
  final tree = <String, List<String>>{
    '0': [container('1', '0', 'Music'), container('3', '0', 'Pictures')],
    '1': [
      container('1\$7', '1', 'Album'),
      container('1\$6', '1', 'Artist'),
      container('1\$5', '1', 'Genre'),
      container('1\$4', '1', 'All Music'),
      container('1\$14', '1', 'Folders'),
    ],
    '1\$7': [
      container('A2', '1\$7', 'Zeta Album', cls: 'object.container.album.musicAlbum'),
      container('A1', '1\$7', 'Alpha Album', cls: 'object.container.album.musicAlbum'),
      container('A1dup', '1\$7', 'Alpha Album', cls: 'object.container.album.musicAlbum'),
    ],
    'A1': [track('T1', 'A1', 'One'), track('T2', 'A1', 'Two'), container('A1cd2', 'A1', 'CD2')],
    'A1cd2': [track('T3', 'A1cd2', 'Three')],
  };

  /// Search answers by criteria.
  final searches = <String, List<String>>{};

  http.Client get client => MockClient((request) async {
    if (request.method == 'GET') {
      if (request.url.path == '/rootDesc.xml') return http.Response(fixture('minidlna_rootDesc.xml'), 200);
      return http.Response('not found', 404);
    }
    final action = RegExp(r'#(\w+)"').firstMatch(request.headers['SOAPAction'] ?? '')!.group(1)!;
    final body = XmlDocument.parse(request.body);
    final call = body.descendants.whereType<XmlElement>().firstWhere((e) => e.name.local == action);
    final args = {for (final e in call.childElements) e.name.local: e.innerText};
    requests.add((action: action, args: args));

    switch (action) {
      case 'GetSearchCapabilities':
        return http.Response(
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
          '<u:GetSearchCapabilitiesResponse xmlns:u="$dlnaContentDirectoryService">'
          '<SearchCaps>$searchCaps</SearchCaps></u:GetSearchCapabilitiesResponse></s:Body></s:Envelope>',
          200,
        );
      case 'Browse':
        final id = args['ObjectID']!;
        if (args['BrowseFlag'] == 'BrowseMetadata') {
          final self = tree.values.expand((c) => c).where((x) => x.contains('id="$id"')).firstOrNull;
          if (self == null && id != '0') return http.Response(fixture('soap_fault.xml'), 500);
          return http.Response(browseResponse(didl(self ?? container('0', '-1', 'root'))), 200);
        }
        final children = tree[id];
        if (children == null) return http.Response(fixture('soap_fault.xml'), 500);
        final start = int.parse(args['StartingIndex']!);
        final count = int.parse(args['RequestedCount']!);
        final page = children.skip(start).take(count == 0 ? children.length : count).toList();
        return http.Response(browseResponse(didl(page.join()), total: children.length), 200);
      case 'Search':
        if (searchCaps.isEmpty) return http.Response(fixture('soap_fault.xml').replaceAll('701', '708'), 500);
        final found = searches[args['SearchCriteria']] ?? const [];
        return http.Response(browseResponse(didl(found.join()), action: 'Search'), 200);
    }
    return http.Response('', 500);
  });
}

MediaSourceConfig dlnaConfig([String address = 'http://192.168.1.10:8200']) =>
    MediaSourceConfig(sourceId: 'dlna1', kind: MediaSourceKind.dlna, name: 'NAS', publicAddress: address);

void main() {
  group('device description', () {
    test('reads a MiniDLNA description', () {
      final location = Uri.parse('http://192.168.1.10:8200/rootDesc.xml');
      final device = parseDeviceDescription(fixture('minidlna_rootDesc.xml'), location);
      expect(device.friendlyName, 'NAS: minidlna');
      expect(device.udn, 'uuid:4d696e69-444c-164e-9d41-b827eb000001');
      expect(device.controlUrl, Uri.parse('http://192.168.1.10:8200/ctl/ContentDir'));
      expect(device.iconUrl, Uri.parse('http://192.168.1.10:8200/icons/lrg.png'));
      expect(device.product, 'Windows Media Connect compatible (MiniDLNA) 1.3.3');
      expect(device.location, location);
    });

    test('resolves a relative control URL against URLBase', () {
      final device = parseDeviceDescription(
        fixture('serviio_description.xml'),
        Uri.parse('http://192.168.1.20:8895/deviceDescription/abc'),
      );
      expect(device.controlUrl, Uri.parse('http://192.168.1.20:8895/serviceControl'));
      expect(device.iconUrl, isNull);
    });

    test('rejects a renderer and broken XML', () {
      final location = Uri.parse('http://tv/desc.xml');
      expect(
        () => parseDeviceDescription(fixture('renderer_description.xml'), location),
        throwsA(isA<DlnaException>()),
      );
      expect(() => parseDeviceDescription('<root><device>', location), throwsA(isA<DlnaException>()));
    });
  });

  group('SOAP', () {
    test('builds an escaped Browse envelope', () {
      final envelope = buildSoapEnvelope('Browse', browseArgs('64\$1&<2>', start: 200, count: 50));
      final doc = XmlDocument.parse(envelope);
      final browse = doc.findAllElements('u:Browse').single;
      expect(browse.getAttribute('xmlns:u'), dlnaContentDirectoryService);
      final args = {for (final e in browse.childElements) e.name.local: e.innerText};
      expect(args, {
        'ObjectID': '64\$1&<2>',
        'BrowseFlag': 'BrowseDirectChildren',
        'Filter': '*',
        'StartingIndex': '200',
        'RequestedCount': '50',
        'SortCriteria': '',
      });
      expect(browse.childElements.map((e) => e.name.local).toList(), [
        'ObjectID',
        'BrowseFlag',
        'Filter',
        'StartingIndex',
        'RequestedCount',
        'SortCriteria',
      ]);
      expect(soapActionHeader('Browse'), '"urn:schemas-upnp-org:service:ContentDirectory:1#Browse"');
    });

    test('metadata browse and search arguments', () {
      expect(browseArgs('7', metadata: true)['BrowseFlag'], 'BrowseMetadata');
      final args = searchArgs('0', searchCriteria('object.container.album.musicAlbum', term: 'a "b" \\c'));
      expect(args['ContainerID'], '0');
      expect(
        args['SearchCriteria'],
        r'upnp:class derivedfrom "object.container.album.musicAlbum" and dc:title contains "a \"b\" \\c"',
      );
      expect(searchCriteria('object.item.audioItem'), 'upnp:class derivedfrom "object.item.audioItem"');
    });

    test('reads a UPnP fault', () {
      final fault = parseFault(fixture('soap_fault.xml'));
      expect(fault, isNotNull);
      expect(fault!.code, 701);
      expect(fault.message, 'No such object error');
      expect(() => parseBrowseResponse(fixture('soap_fault.xml')), throwsA(isA<DlnaFault>()));
      expect(parseFault(browseResponse(didl(''))), isNull);
    });

    test('reads search capabilities', () {
      String caps(String c) =>
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:R xmlns:u="x">'
          '<SearchCaps>$c</SearchCaps></u:R></s:Body></s:Envelope>';
      expect(parseSearchCapabilities(caps('dc:title, upnp:class,upnp:artist')), {
        'dc:title',
        'upnp:class',
        'upnp:artist',
      });
      expect(parseSearchCapabilities(caps('')), isEmpty);
    });
  });

  group('DIDL-Lite', () {
    test('reads tracks, resources and containers', () {
      final objects = parseDidl(
        fixture('didl_album_tracks.xml'),
        base: Uri.parse('http://192.168.1.10:8200/ctl/ContentDir'),
      );
      expect(objects, hasLength(4));

      final first = objects[0];
      expect(first.id, '64\$1\$0\$0');
      expect(first.parentId, '64\$1\$0');
      expect(first.refId, '64\$0\$A');
      expect(first.title, 'Intro & Outro');
      expect(first.isAudioItem, isTrue);
      expect(first.artists, ['Main Artist']);
      expect(first.albumArtist, 'Various Artists');
      expect(first.displayArtist, 'Main Artist');
      expect(first.album, 'Great Album');
      expect(first.genres, ['Rock']);
      expect(first.trackNumber, 3);
      expect(first.discNumber, 2);
      expect(first.year, 2019);
      expect(first.artUri, Uri.parse('http://192.168.1.10:8200/AlbumArt/42-17.jpg'));
      expect(first.resources, hasLength(2));
      expect(first.resources[0].isRawPcm, isTrue);
      expect(first.resources[0].isConverted, isTrue);

      final best = first.bestAudioResource!;
      expect(best.uri, Uri.parse('http://192.168.1.10:8200/MediaItems/17.flac'));
      expect(best.container, 'flac');
      expect(best.duration, const Duration(minutes: 4, seconds: 5, milliseconds: 500));
      expect(best.size, 29360128);
      expect(best.bitrate, 120000);
      expect(best.sampleFrequency, 44100);
      expect(best.bitsPerSample, 16);
      expect(best.channels, 2);

      final second = objects[1];
      expect(second.bestAudioResource!.uri, Uri.parse('http://192.168.1.10:8200/MediaItems/18.mp3'));
      expect(second.bestAudioResource!.container, 'mp3');
      expect(second.refId, isNull);

      expect(objects[2].isAudioItem, isFalse);
      expect(objects[2].bestAudioResource, isNull);

      final cd2 = objects[3];
      expect(cd2.isContainer, isTrue);
      expect(cd2.childCount, 5);
      expect(cd2.isMusicAlbum, isFalse);
    });

    test('tolerates undeclared prefixes and relative art', () {
      final objects = parseDidl(fixture('didl_undeclared_prefixes.xml'), base: Uri.parse('http://nas:9000/ctl'));
      final album = objects.single;
      expect(album.isMusicAlbum, isTrue);
      expect(album.title, 'Some Album');
      expect(album.displayArtist, 'Someone');
      expect(album.childCount, 12);
      expect(album.artUri, Uri.parse('http://nas:9000/art/7.jpg'));
    });

    test('reads the listing inside a Browse answer', () {
      final result = parseBrowseResponse(
        browseResponse(fixture('didl_album_tracks.xml'), returned: 4, total: 10),
        base: Uri.parse('http://192.168.1.10:8200/ctl/ContentDir'),
      );
      expect(result.objects, hasLength(4));
      expect(result.numberReturned, 4);
      expect(result.totalMatches, 10);
    });

    test('durations', () {
      expect(parseDidlDuration('1:02:03'), const Duration(hours: 1, minutes: 2, seconds: 3));
      expect(parseDidlDuration('0:00:01.5'), const Duration(seconds: 1, milliseconds: 500));
      expect(parseDidlDuration('0:00:01.123456'), const Duration(seconds: 1, milliseconds: 123));
      expect(parseDidlDuration('nonsense'), isNull);
      expect(parseDidlDuration('0:61:00'), isNull);
    });
  });

  group('SSDP', () {
    test('M-SEARCH for media servers', () {
      final message = buildMSearch();
      expect(message, startsWith('M-SEARCH * HTTP/1.1\r\n'));
      expect(message, contains('HOST: 239.255.255.250:1900\r\n'));
      expect(message, contains('MAN: "ssdp:discover"\r\n'));
      expect(message, contains('ST: urn:schemas-upnp-org:device:MediaServer:1\r\n'));
      expect(message, endsWith('\r\n\r\n'));
    });

    test('reads LOCATION from an answer', () {
      const answer =
          'HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1810\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\n'
          'Location: http://192.168.1.10:8200/rootDesc.xml\r\nUSN: uuid:x::urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n';
      expect(parseSsdpLocation(answer), Uri.parse('http://192.168.1.10:8200/rootDesc.xml'));
      expect(parseSsdpLocation('HTTP/1.1 200 OK\r\nLOCATION: nonsense\r\n\r\n'), isNull);
    });
  });

  group('DlnaClient', () {
    test('probes the usual description paths of a host:port', () async {
      final server = FakeDlnaServer();
      final device = await DlnaClient(client: server.client).probe('192.168.1.10:8200');
      expect(device.location, Uri.parse('http://192.168.1.10:8200/rootDesc.xml'));
      expect(device.controlUrl, Uri.parse('http://192.168.1.10:8200/ctl/ContentDir'));
    });
  });

  group('DlnaBackend', () {
    test('matches view containers by title', () {
      final views = DlnaBackend.matchViews(
        parseDidl(
          didl(
            container('a', '1', 'Album') +
                container('b', '1', 'Album Artist') +
                container('c', '1', 'Genre') +
                container('d', '1', 'All Music') +
                container('e', '1', 'Folders') +
                container('f', '1', '- Playlists -'),
          ),
        ),
      );
      expect(views, {
        DlnaView.albums: 'a',
        DlnaView.artists: 'b',
        DlnaView.genres: 'c',
        DlnaView.tracks: 'd',
        DlnaView.folders: 'e',
        DlnaView.playlists: 'f',
      });
    });

    test('lists albums by browsing the views, deduplicated and sorted', () async {
      final server = FakeDlnaServer();
      final backend = DlnaBackend(dlnaConfig(), client: DlnaClient(client: server.client));
      expect(await backend.ping(), isTrue);

      final albums = await backend.getItems(includeItemTypes: 'MusicAlbum', sortBy: 'SortName');
      expect(albums.map((a) => a.name), ['Alpha Album', 'Zeta Album']);
      expect(albums.first.type, 'MusicAlbum');
      expect(albums.first.id.nativeId, 'A1');
      expect(server.requests.where((r) => r.action == 'Search'), isEmpty);
    });

    test('album tracks include disc sub-folders, and stream the res URL', () async {
      final server = FakeDlnaServer();
      final backend = DlnaBackend(dlnaConfig(), client: DlnaClient(client: server.client));
      final album = (await backend.getItems(includeItemTypes: 'MusicAlbum')).firstWhere((a) => a.name == 'Alpha Album');

      final tracks = await backend.getItems(parentItem: album, includeItemTypes: 'Audio');
      expect(tracks.map((t) => t.name), ['One', 'Two', 'Three']);
      expect(tracks.first.type, 'Audio');
      expect(tracks.first.runTimeTicks, const Duration(minutes: 3).inMicroseconds * 10);

      final stream = await backend.resolveStream(tracks.first, transcode: false);
      expect(stream.uri, Uri.parse('http://192.168.1.10:8200/MediaItems/T1.mp3'));
      expect(stream.container, 'mp3');
      final download = await backend.resolveDownload(tracks.last);
      expect(download.uri, Uri.parse('http://192.168.1.10:8200/MediaItems/T3.mp3'));
    });

    test('resolves a stream it has not listed with BrowseMetadata', () async {
      final server = FakeDlnaServer();
      final backend = DlnaBackend(dlnaConfig(), client: DlnaClient(client: server.client));
      final item = await backend.getItemById(BaseItemId.scoped('dlna1', 'T2'));
      expect(item!.name, 'Two');

      final fresh = DlnaBackend(dlnaConfig(), client: DlnaClient(client: server.client));
      final stream = await fresh.resolveStream(item, transcode: false);
      expect(stream.uri, Uri.parse('http://192.168.1.10:8200/MediaItems/T2.mp3'));
      expect(server.requests.last.args['BrowseFlag'], 'BrowseMetadata');

      expect(await backend.getItemById(BaseItemId.scoped('dlna1', 'missing')), isNull);
    });

    test('folder view hides picture and video roots', () async {
      final server = FakeDlnaServer();
      final backend = DlnaBackend(dlnaConfig(), client: DlnaClient(client: server.client));
      final top = await backend.getItems();
      expect(top.map((i) => i.name), ['Music']);
      final inside = await backend.getItems(parentItem: top.single);
      expect(inside.map((i) => i.name), ['Album', 'Artist', 'Genre', 'All Music', 'Folders']);
      expect(inside.first.type, 'Folder');
    });

    test('without server search, matches album names locally', () async {
      final server = FakeDlnaServer();
      final backend = DlnaBackend(dlnaConfig(), client: DlnaClient(client: server.client));
      final found = await backend.getItems(searchTerm: 'zeta', includeItemTypes: 'MusicAlbum');
      expect(found.map((i) => i.name), ['Zeta Album']);
    });

    test('uses Search when the server supports it', () async {
      final server = FakeDlnaServer(searchCaps: 'dc:title,upnp:class,upnp:artist');
      server.searches[searchCriteria('object.container.album.musicAlbum')] = [
        container('S1', 'x', 'Searched Album', cls: 'object.container.album.musicAlbum'),
      ];
      server.searches[searchCriteria('object.item.audioItem', term: 'one')] = [track('T1', 'A1', 'One')];
      final backend = DlnaBackend(dlnaConfig(), client: DlnaClient(client: server.client));

      final albums = await backend.getItems(includeItemTypes: 'MusicAlbum');
      expect(albums.map((a) => a.name), ['Searched Album']);

      final tracks = await backend.getItems(searchTerm: 'one', includeItemTypes: 'Audio');
      expect(tracks.map((t) => t.name), ['One']);
      expect(server.requests.where((r) => r.action == 'Search').last.args['ContainerID'], '0');
    });

    test('an unreachable server lists nothing and fails ping', () async {
      final client = MockClient((_) async => throw const SocketException('unreachable'));
      final backend = DlnaBackend(dlnaConfig(), client: DlnaClient(client: client));
      expect(await backend.ping(), isFalse);
      expect(await backend.getItems(includeItemTypes: 'MusicAlbum'), isEmpty);
    });
  });

  group('DlnaDiscoveryList', () {
    Widget wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

    testWidgets('lists found servers and reports the one picked', (tester) async {
      final device = parseDeviceDescription(
        fixture('minidlna_rootDesc.xml'),
        Uri.parse('http://192.168.1.10:8200/rootDesc.xml'),
      );
      DlnaDevice? picked;
      await tester.pumpWidget(wrap(DlnaDiscoveryList(discover: () async => [device], onSelected: (d) => picked = d)));
      await tester.pump();
      expect(find.text('NAS: minidlna'), findsOneWidget);
      await tester.tap(find.text('NAS: minidlna'));
      expect(picked?.udn, device.udn);
    });

    testWidgets('says when nothing answered', (tester) async {
      await tester.pumpWidget(
        wrap(DlnaDiscoveryList(discover: () async => throw const SocketException('denied'), onSelected: (_) {})),
      );
      await tester.pump();
      expect(find.textContaining('No media server found'), findsOneWidget);
    });
  });
}

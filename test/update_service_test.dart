import 'dart:convert';
import 'dart:io';

import 'package:diapason/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

Map<String, dynamic> _release(String tag, {String body = '', List<dynamic>? assets, Map<String, dynamic>? extra}) => {
  'tag_name': tag,
  'body': body,
  'html_url': 'https://github.com/Nytuo/diapason/releases/tag/$tag',
  'assets': assets ?? [],
  ...?extra,
};

UpdateService _service(http.Response Function(http.Request) reply, {List<Uri>? seen}) => UpdateService(
  client: MockClient((req) async {
    seen?.add(req.url);
    return reply(req);
  }),
);

http.Response _json(Object o, [int status = 200]) => http.Response(jsonEncode(o), status);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Diapason',
      packageName: 'fr.nytuo.diapason',
      version: '1.2.3',
      buildNumber: '10',
      buildSignature: '',
    );
  });

  test('asks GitHub for the latest release of the configured repository', () async {
    final seen = <Uri>[];
    await _service((_) => _json(_release('v1.2.3')), seen: seen).checkForUpdate();
    expect(seen.single.toString(), 'https://api.github.com/repos/Nytuo/diapason/releases/latest');
  });

  test('a newer version is reported with the leading v stripped', () async {
    final info = await _service((_) => _json(_release('v1.3.0', body: 'Fixes'))).checkForUpdate();
    expect(info!.version, '1.3.0');
    expect(info.currentVersion, '1.2.3');
    expect(info.notes, 'Fixes');
    expect(info.force, isFalse);
    expect(info.downloadUrl, info.releaseUrl);
  });

  test('the same or an older version is no update, unless asked to ignore versions', () async {
    final same = _service((_) => _json(_release('v1.2.3')));
    expect(await same.checkForUpdate(), isNull);
    expect(await _service((_) => _json(_release('1.1.9'))).checkForUpdate(), isNull);
    expect((await same.checkForUpdate(ignoreVersion: true))!.version, '1.2.3');
  });

  test('versions compare number by number, not as text', () async {
    expect((await _service((_) => _json(_release('v1.10.0'))).checkForUpdate())!.version, '1.10.0');
    expect(await _service((_) => _json(_release('v1.2'))).checkForUpdate(), isNull);
    expect((await _service((_) => _json(_release('v1.2.3.1'))).checkForUpdate())!.version, '1.2.3.1');
    expect((await _service((_) => _json(_release('v2.0.0-beta+4'))).checkForUpdate())!.version, '2.0.0-beta+4');
  });

  test('[force] in the notes makes the update mandatory and is removed from the notes', () async {
    for (final marker in ['[force]', '[FORCE-UPDATE]', '[force update]']) {
      final info = await _service((_) => _json(_release('v9.0.0', body: 'Security fix $marker'))).checkForUpdate();
      expect(info!.force, isTrue, reason: marker);
      expect(info.notes, 'Security fix', reason: marker);
    }
  });

  test('drafts, prereleases, empty tags and malformed bodies are ignored', () async {
    expect(await _service((_) => _json(_release('v9.0.0', extra: {'draft': true}))).checkForUpdate(), isNull);
    expect(await _service((_) => _json(_release('v9.0.0', extra: {'prerelease': true}))).checkForUpdate(), isNull);
    expect(await _service((_) => _json(_release(''))).checkForUpdate(), isNull);
    expect(await _service((_) => http.Response('<html>', 200)).checkForUpdate(), isNull);
  });

  test('HTTP errors and network failures mean "no update", never a crash', () async {
    expect(await _service((_) => http.Response('rate limited', 403)).checkForUpdate(), isNull);
    final failing = UpdateService(client: MockClient((_) async => throw Exception('offline')));
    expect(await failing.checkForUpdate(), isNull);
  });

  test('a missing html_url falls back to the repository releases page', () async {
    final body = _release('v5.0.0')..remove('html_url');
    final info = await _service((_) => _json(body)).checkForUpdate();
    expect(info!.releaseUrl, 'https://github.com/Nytuo/diapason/releases/latest');
  });

  test('assets for this platform are offered; unusable entries are skipped', () async {
    final assets = <dynamic>[
      {'name': 'diapason.apk', 'browser_download_url': 'https://x/apk'},
      {'name': 'diapason_macos_arm64.dmg', 'browser_download_url': 'https://x/mac-arm'},
      {'name': 'diapason_macos_x64.dmg', 'browser_download_url': 'https://x/mac-x64'},
      {'name': 'diapason_windows_x64.exe', 'browser_download_url': 'https://x/win'},
      {'name': 'diapason_linux_x64.AppImage', 'browser_download_url': 'https://x/linux'},
      {'name': 'notes.txt', 'browser_download_url': 'https://x/notes'},
    ];
    final body = _release(
      'v9.0.0',
      assets: <dynamic>[
        {'name': 'diapason_macos.dmg'},
        'junk',
        ...assets,
      ],
    );
    final info = await _service((_) => _json(body)).checkForUpdate();
    expect(info!.assetUrl, isNotNull);
    expect(info.assetUrl, isNot('https://x/notes'));
    expect(info.downloadUrl, info.assetUrl);
  });

  test('no matching asset means the release page is the download', () async {
    final info = await _service(
      (_) => _json(
        _release(
          'v9.0.0',
          assets: [
            {'name': 'readme.txt', 'browser_download_url': 'https://x/r'},
          ],
        ),
      ),
    ).checkForUpdate();
    expect(info!.assetUrl, isNull);
    expect(info.downloadUrl, info.releaseUrl);
  });

  test('in-app install is only offered where an installer can run', () {
    expect(UpdateService.canInstallInApp(null), isFalse);
    // Desktop test hosts: macOS yes, Linux no (packages cannot be installed unattended).
    final expected = Platform.isAndroid || Platform.isWindows || Platform.isMacOS;
    expect(UpdateService.canInstallInApp('https://x/y'), expected);
  });

  test('UpdateException prints its message', () {
    expect(const UpdateException('nope').toString(), 'nope');
  });
}

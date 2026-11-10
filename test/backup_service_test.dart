import 'dart:convert';
import 'dart:typed_data';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/backup/backup_service.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_env.dart';

void main() {
  late TestEnv env;

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
  });

  tearDown(() async => env.dispose());

  test('settings survive the round trip through a backup', () async {
    env.updateSettings((s) {
      s.crossfadeSeconds = 7;
      s.lastFmSessionKey = "secret-session";
      s.uploaderToken = "secret-token";
    });

    final bytes = await BackupService.encodeSettings(FinampSettingsHelper.finampSettings, includeSignIns: true);
    final restored = await BackupService.decodeSettings(bytes);

    expect(restored.crossfadeSeconds, 7);
    expect(restored.lastFmSessionKey, "secret-session");
    expect(restored.uploaderToken, "secret-token");
  });

  test('a backup without sign-ins drops the secrets but leaves the live settings alone', () async {
    env.updateSettings((s) {
      s.crossfadeSeconds = 4;
      s.lastFmSessionKey = "secret-session";
      s.listenBrainzToken = "lb";
    });

    final bytes = await BackupService.encodeSettings(FinampSettingsHelper.finampSettings, includeSignIns: false);
    final restored = await BackupService.decodeSettings(bytes);

    expect(restored.crossfadeSeconds, 4);
    expect(restored.lastFmSessionKey, isEmpty);
    expect(restored.listenBrainzToken, isEmpty);
    expect(FinampSettingsHelper.finampSettings.lastFmSessionKey, "secret-session");
  });

  test('restoring keeps this device\'s download folders, window and sign-ins the backup lacks', () async {
    final current = FinampSettingsHelper.finampSettings
      ..screenSize = ScreenSize(500, 400, 10, 20)
      ..lastFmSessionKey = "mine";
    final restored = await FinampSettings.create()
      ..crossfadeSeconds = 9
      ..downloadLocationsMap = {}
      ..lastFmSessionKey = ""
      ..uploaderToken = "theirs";

    final merged = BackupService.mergeForThisDevice(restored, current);

    expect(merged.crossfadeSeconds, 9);
    expect(merged.downloadLocationsMap.keys, current.downloadLocationsMap.keys);
    expect(merged.screenSize?.sizeX, 500);
    expect(merged.lastFmSessionKey, "mine", reason: "an empty secret in the backup doesn't sign this device out");
    expect(merged.uploaderToken, "theirs");
  });

  group('the file itself', () {
    Uint8List file(Map<String, dynamic> json) => Uint8List.fromList(utf8.encode(jsonEncode(json)));

    test('something else is refused', () {
      expect(() => BackupService.parse(Uint8List.fromList(utf8.encode("hello"))), throwsA(isA<BackupFormatException>()));
      expect(() => BackupService.parse(file({"format": "other"})), throwsA(isA<BackupFormatException>()));
    });

    test('a backup from a newer app is refused with a hint', () {
      expect(
        () => BackupService.parse(file({"format": BackupService.format, "version": BackupService.version + 1})),
        throwsA(isA<BackupFormatException>().having((e) => e.message, "message", contains("newer"))),
      );
    });

    test('a current backup is accepted', () {
      final json = BackupService.parse(file({"format": BackupService.format, "version": BackupService.version}));
      expect(json["version"], BackupService.version);
    });

    test('the suggested name carries the date', () {
      expect(BackupService.suggestedFileName(DateTime(2026, 3, 7)), "diapason-backup-2026-03-07.json");
    });
  });
}

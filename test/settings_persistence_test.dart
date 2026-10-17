import 'dart:io';

import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/discord_rpc.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/log_level.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/binary/binary_reader_impl.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:logging/logging.dart';

import 'support/test_env.dart';

void main() {
  late TestEnv env;

  setUp(() async {
    env = await TestEnv.create();
    await env.openHive();
  });

  tearDown(() => env.dispose());

  group('defaults for a new install', () {
    test('YouTube goes through the uploader when one is configured, and nothing else is on by surprise', () {
      final s = FinampSettingsHelper.finampSettings;

      expect(s.uploaderYtProxy, isTrue);
      expect(s.uploaderEnabled, isFalse, reason: 'auto-upload is opt-in');
      expect(s.uploaderUrl, isEmpty);
      expect(s.uploaderToken, isEmpty);
      expect(s.uploaderNetworkPolicy, 'local', reason: 'the safe policy');
      expect(s.uploaderAllowInsecure, isFalse);
      expect(s.uploaderWifiOnly, isFalse);
      expect(s.rpcEnabled, isFalse, reason: 'Rich Presence shares what you listen to; it is opt-in');
      expect(s.youtubeResultCount, 20);
      expect(s.youtubeShowHits, isTrue);
      expect(s.youtubeShowNew, isTrue);
      expect(s.youtubeSearchByDefault, isFalse);
      expect(s.logLevel, 'all');
      expect(s.ytdlpConfigJson, isEmpty);
    });
  });

  group('settings survive a restart', () {
    test('every setting added for YouTube, the uploader and diagnostics', () async {
      env.updateSettings((s) {
        s.uploaderEnabled = true;
        s.uploaderUrl = 'https://music.example.com';
        s.uploaderToken = 'abc';
        s.uploaderNetworkPolicy = 'internet';
        s.uploaderYtProxy = false;
        s.uploaderAllowInsecure = true;
        s.uploaderWifiOnly = true;
        s.youtubeResultCount = 40;
        s.youtubeShowHits = false;
        s.youtubeShowNew = false;
        s.youtubeSearchByDefault = true;
        s.logLevel = 'warning';
        s.ytdlpConfigJson = '{"retries":9}';
        s.rpcEnabled = true;
      });

      await Hive.close();
      await Hive.openBox<FinampSettings>('FinampSettings');
      final s = FinampSettingsHelper.finampSettings;

      expect(s.uploaderEnabled, isTrue);
      expect(s.uploaderUrl, 'https://music.example.com');
      expect(s.uploaderToken, 'abc');
      expect(s.uploaderNetworkPolicy, 'internet');
      expect(s.uploaderYtProxy, isFalse);
      expect(s.uploaderAllowInsecure, isTrue);
      expect(s.uploaderWifiOnly, isTrue);
      expect(s.youtubeResultCount, 40);
      expect(s.youtubeShowHits, isFalse);
      expect(s.youtubeShowNew, isFalse);
      expect(s.youtubeSearchByDefault, isTrue);
      expect(s.logLevel, 'warning');
      expect(s.ytdlpConfigJson, '{"retries":9}');
      expect(s.rpcEnabled, isTrue);
    });

    test('settings written by an older version, before these fields existed, load with sensible defaults', () {
      // Re-encode the stored settings without the newest fields, as an old version would have written them.
      const newest = {188, 189, 190, 191, 192, 193, 194, 195, 196};
      final adapter = FinampSettingsAdapter();
      final current = FinampSettingsHelper.finampSettings
        ..uploaderYtProxy = false
        ..youtubeResultCount = 50;

      final writer = BinaryWriterImpl(Hive);
      adapter.write(writer, current);
      final reader = BinaryReaderImpl(writer.toBytes(), Hive);
      final count = reader.readByte();
      final fields = <int, dynamic>{};
      for (var i = 0; i < count; i++) {
        final index = reader.readByte();
        fields[index] = reader.read();
      }
      expect(fields.keys.toSet().intersection(newest), isNotEmpty, reason: 'the fixture really has the new fields');

      final old = BinaryWriterImpl(Hive);
      final kept = fields.entries.where((e) => !newest.contains(e.key)).toList();
      old.writeByte(kept.length);
      for (final e in kept) {
        old.writeByte(e.key);
        old.write(e.value);
      }
      final loaded = adapter.read(BinaryReaderImpl(old.toBytes(), Hive));

      expect(loaded.uploaderYtProxy, isTrue, reason: 'default, not the false that was stored');
      expect(loaded.youtubeResultCount, 20);
      expect(loaded.logLevel, 'all');
      expect(loaded.uploaderWifiOnly, isFalse);
      expect(loaded.downloadLocationsMap, isNotEmpty, reason: 'and the old data itself is intact');
    });
  });

  group('Hive field numbers', () {
    // Two fields sharing a number in one class silently overwrite each other's data on disk.
    test('are unique inside every stored class', () {
      final source = File('lib/models/finamp_models.dart').readAsStringSync();
      // Every top-level declaration, so one class's fields can't be blamed on its neighbour.
      final decls = RegExp(
        r'^(@HiveType\(typeId: \d+\)\s*)?(?:abstract )?(?:class|enum) (\w+)',
        multiLine: true,
      ).allMatches(source).toList();
      var checked = 0;

      for (var i = 0; i < decls.length; i++) {
        if (decls[i].group(1) == null) continue;
        checked++;
        final end = i + 1 < decls.length ? decls[i + 1].start : source.length;
        final seen = <String>{};
        for (final m in RegExp(r'^\s*@HiveField\((\d+)', multiLine: true).allMatches(source.substring(decls[i].end, end))) {
          expect(seen.add(m.group(1)!), isTrue, reason: '${decls[i].group(2)} uses HiveField(${m.group(1)}) twice');
        }
      }
      expect(checked, greaterThan(5));
    });

    test('type ids are unique across the whole app', () {
      final seen = <String, String>{};
      for (final file
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'))) {
        for (final m in RegExp(
          r'@HiveType\(typeId: (\d+)\)\s*(?:enum|class|abstract class)\s+(\w+)',
        ).allMatches(file.readAsStringSync())) {
          final previous = seen[m.group(1)!];
          expect(previous, isNull, reason: 'typeId ${m.group(1)} is used by both $previous and ${m.group(2)}');
          seen[m.group(1)!] = m.group(2)!;
        }
      }
      expect(seen, isNotEmpty);
    });
  });

  group('log detail', () {
    final before = Logger.root.level;
    tearDown(() => Logger.root.level = before);

    test('maps the saved choice to a logger level, falling back to everything', () {
      expect(LogDetail.fromId('info').level, Level.INFO);
      expect(LogDetail.fromId('warning').level, Level.WARNING);
      expect(LogDetail.fromId('all').level, Level.ALL);
      expect(LogDetail.fromId('garbage').level, Level.ALL);
    });

    test('applying it changes what the app logs', () {
      env.updateSettings((s) => s.logLevel = 'warning');

      applyConfiguredLogLevel();

      expect(Logger.root.level, Level.WARNING);
      expect(Logger.root.isLoggable(Level.INFO), isFalse);
      expect(Logger.root.isLoggable(Level.SEVERE), isTrue);
    });
  });

  group('Discord Rich Presence', () {
    test('only public, credential-free cover URLs are ever handed to Discord', () {
      String? share(String url) => DiscordRpc.shareableImage(Uri.parse(url));

      expect(share('https://img.example.com/cover.jpg?size=128'), isNotNull);
      // Subsonic/Navidrome signed URLs carry a password hash and salt.
      expect(share('https://music.example.com/rest/getCoverArt.view?id=1&u=me&t=abc&s=def'), isNull);
      expect(share('https://music.example.com/cover?api_key=SECRET'), isNull);
      expect(share('https://plex.example.com/thumb?X-Plex-Token=SECRET'), isNull);
      // Discord's servers cannot reach private addresses anyway, and the address itself is private information.
      expect(share('http://192.168.1.10:4533/cover'), isNull);
      expect(share('http://localhost:8096/cover'), isNull);
      expect(share('ftp://example.com/x.jpg'), isNull);
      expect(DiscordRpc.shareableImage(null), isNull);
    });

    test('recognises home-network addresses', () {
      expect(DiscordRpc.isAddressInLocalAddressRange('http://192.168.0.5'), isTrue);
      expect(DiscordRpc.isAddressInLocalAddressRange('http://10.1.2.3:8096'), isTrue);
      expect(DiscordRpc.isAddressInLocalAddressRange('http://172.20.0.1'), isTrue);
      expect(DiscordRpc.isAddressInLocalAddressRange('http://jellyfin:8096'), isTrue, reason: 'a bare docker name');
      expect(DiscordRpc.isAddressInLocalAddressRange('https://music.example.com'), isFalse);
      expect(DiscordRpc.isAddressInLocalAddressRange('http://8.8.8.8'), isFalse);
    });

    test('uses the Diapason Discord application', () {
      expect(DiscordRpc.applicationId, '1507760797823275098');
    });
  });
}

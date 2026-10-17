import 'dart:async';
import 'dart:io';

import 'package:chopper/chopper.dart' as chopper;
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/youtube/ytdlp_errors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Whatever goes wrong, the person sees a sentence about what to do, the log keeps the technical truth.
void main() {
  group('plain-language messages', () {
    test('a name that does not resolve', () {
      final d = FriendlyError.describe(const SocketException("Failed host lookup: 'nas.local'"));

      expect(d.message, 'Couldn\'t find that server. Check the address and your internet connection.');
      expect(d.source, ErrorSource.connection);
      expect(d.technical, contains("Failed host lookup: 'nas.local'"));
    });

    test('a server that is not listening', () {
      expect(FriendlyError.message(const SocketException('Connection refused')), contains('refused the connection'));
    });

    test('any other socket trouble', () {
      expect(FriendlyError.message(const SocketException('Network is unreachable')), contains('Check your network'));
    });

    test('a timeout', () {
      final d = FriendlyError.describe(TimeoutException('slow', const Duration(seconds: 5)));

      expect(d.message, contains('too long'));
      expect(d.source, ErrorSource.connection);
    });

    test('a certificate problem is not shown as a generic failure', () {
      expect(FriendlyError.message(const HandshakeException('CERTIFICATE_VERIFY_FAILED')), contains('certificate'));
      expect(FriendlyError.message(const TlsException('bad')), contains('secure connection'));
    });

    test('an interrupted HTTP call', () {
      expect(FriendlyError.message(http.ClientException('Connection closed')), contains('interrupted'));
    });

    test('unexpected content from a server', () {
      expect(FriendlyError.describe(const FormatException('Unexpected character')).message, contains('unexpected'));
    });

    test('Jellyfin/Chopper responses by status', () {
      String forStatus(int code) => FriendlyError.message(chopper.Response<dynamic>(http.Response('', code), null));

      expect(forStatus(401), contains('login'));
      expect(forStatus(403), contains('login'));
      expect(forStatus(404), contains('couldn\'t find'));
      expect(forStatus(429), contains('slow down'));
      expect(forStatus(504), contains('too long'));
      expect(forStatus(503), contains('problem handling'));
      expect(forStatus(418), contains('418'));
    });

    test('disk problems on this device', () {
      FileSystemException withCode(int code) => FileSystemException('x', '/p', OSError('os', code));

      expect(FriendlyError.message(withCode(28)), contains('free space'));
      expect(FriendlyError.message(withCode(13)), contains('permission'));
      expect(FriendlyError.describe(withCode(28)).source, ErrorSource.device);
      expect(FriendlyError.message(withCode(2)), contains('file on this device'));
    });

    test('anything unrecognised still gets a human sentence, and is flagged unknown', () {
      final d = FriendlyError.describe(StateError('boom'));

      expect(d.source, ErrorSource.unknown);
      expect(d.message, isNot(contains('StateError')));
      expect(d.technical, contains('StateError: Bad state: boom'));
    });

    test('null is survivable', () {
      expect(FriendlyError.message(null), isNotEmpty);
    });
  });

  group('exceptions that explain themselves', () {
    test('keep the message for people and the detail for the log, separately', () {
      const e = AppException(
        'YouTube is rate-limiting this server.',
        source: ErrorSource.ytdlp,
        code: 'youtube_rate_limited',
        detail: 'HTTP Error 429: Too Many Requests',
        requestId: 'ab12cd34',
      );

      expect(e.toString(), 'YouTube is rate-limiting this server.');
      expect(
        e.technical,
        allOf(
          contains('source=ytdlp'),
          contains('code=youtube_rate_limited'),
          contains('requestId=ab12cd34'),
          contains('429'),
        ),
      );
      expect(FriendlyError.describe(e).message, e.message);
    });

    test('a bare message still has a technical line', () {
      expect(const AppException('x').technical, 'source=unknown');
    });

    test('every source has a short label for the UI', () {
      expect(
        {for (final s in ErrorSource.values) s: s.label},
        {
          ErrorSource.connection: 'Connection',
          ErrorSource.uploader: 'Your uploader',
          ErrorSource.ytdlp: 'yt-dlp',
          ErrorSource.device: 'This device',
          ErrorSource.unknown: 'Unexpected',
        },
      );
    });
  });

  group('logging', () {
    test('report() returns the friendly text and logs the technical one with the stack', () {
      final records = <LogRecord>[];
      final logger = Logger('FriendlyErrorTest');
      final previous = Logger.root.level;
      Logger.root.level = Level.ALL;
      addTearDown(() => Logger.root.level = previous);
      final sub = logger.onRecord.listen(records.add);
      addTearDown(sub.cancel);

      final text = FriendlyError.report(
        logger,
        'Searching YouTube',
        const SocketException('Connection refused'),
        StackTrace.current,
      );

      expect(text, contains('refused the connection'));
      expect(records, hasLength(1));
      expect(records.single.level, Level.WARNING);
      expect(
        records.single.message,
        allOf(contains('Searching YouTube'), contains('connection'), contains('Connection refused')),
      );
      expect(records.single.stackTrace, isNotNull);
    });
  });

  group('yt-dlp messages never leak raw stderr into sentences for people', () {
    const stderrs = [
      'ERROR: [youtube] abc: Sign in to confirm you’re not a bot',
      'ERROR: [youtube] abc: Video unavailable',
      'ERROR: unable to download video data: HTTP Error 429: Too Many Requests',
      'ERROR: [youtube] abc: Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided>',
      'WARNING: No supported JavaScript runtime could be found',
      'ERROR: [youtube] abc: Requested format is not available',
      'ERROR: Sign in to confirm your age. This video may be inappropriate for some users.',
      'ERROR: something unforeseen happened',
    ];

    for (final stderr in stderrs) {
      test(stderr, () {
        final failure = YtDlpFailure.classify(stderr);

        expect(failure.message, isNot(contains('ERROR')));
        expect(failure.message, isNot(contains('WARNING')));
        expect(failure.message, isNot(contains('urlopen')));
        expect(failure.detail, isNotEmpty);
        expect(failure.source, ErrorSource.ytdlp);
      });
    }

    test('the machine named in the message is the one that was used', () {
      expect(YtDlpFailure.classify('Sign in to confirm you\'re not a bot').message, contains('this computer'));
      expect(
        YtDlpFailure.classify('Sign in to confirm you\'re not a bot', where: 'your server').message,
        contains('your server'),
      );
    });
  });
}

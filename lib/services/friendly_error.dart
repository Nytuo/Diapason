import 'dart:async';
import 'dart:io';

import 'package:chopper/chopper.dart' as chopper;
import 'package:diapason/components/global_snackbar.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

enum ErrorSource { connection, uploader, ytdlp, device, unknown }

extension ErrorSourceLabel on ErrorSource {
  String get label => switch (this) {
    ErrorSource.connection => GlobalSnackbar.requireL10n.errorSourceConnection,
    ErrorSource.uploader => GlobalSnackbar.requireL10n.errorSourceUploader,
    ErrorSource.ytdlp => "yt-dlp",
    ErrorSource.device => GlobalSnackbar.requireL10n.errorSourceDevice,
    ErrorSource.unknown => GlobalSnackbar.requireL10n.errorSourceUnexpected,
  };
}

class AppException implements Exception {
  const AppException(this.message, {this.source = ErrorSource.unknown, this.code, this.detail, this.requestId});

  final String message;
  final ErrorSource source;

  final String? code;
  final String? detail;

  final String? requestId;

  @override
  String toString() => message;

  String get technical => [
    "source=${source.name}",
    if (code != null) "code=$code",
    if (requestId != null) "requestId=$requestId",
    if (detail != null && detail!.isNotEmpty) "detail=$detail",
  ].join(" ");
}

class FriendlyError {
  static final _log = Logger("FriendlyError");

  static String message(Object? error) => describe(error).message;

  static ({String message, ErrorSource source, String technical}) describe(Object? error) {
    if (error is AppException) {
      return (message: error.message, source: error.source, technical: error.technical);
    }
    final technical = "${error.runtimeType}: $error";

    if (error is TimeoutException) {
      return (message: GlobalSnackbar.requireL10n.errorTimeout, source: ErrorSource.connection, technical: technical);
    }
    if (error is HandshakeException || error is TlsException) {
      return (message: GlobalSnackbar.requireL10n.errorTls, source: ErrorSource.connection, technical: technical);
    }
    if (error is SocketException) {
      final text = error.toString().toLowerCase();
      final message = text.contains("failed host lookup") || text.contains("nodename nor servname")
          ? GlobalSnackbar.requireL10n.errorHostLookup
          : text.contains("connection refused")
          ? GlobalSnackbar.requireL10n.errorConnectionRefused
          : text.contains("no route to host") || text.contains("network is unreachable") || text.contains("errno = 65")
          ? GlobalSnackbar.requireL10n.errorNoRoute
          : GlobalSnackbar.requireL10n.errorCouldntConnect(
              error.osError?.message.isNotEmpty ?? false ? error.osError!.message : error.message,
            );
      return (message: message, source: ErrorSource.connection, technical: technical);
    }
    if (error is http.ClientException) {
      return (
        message: GlobalSnackbar.requireL10n.errorInterrupted,
        source: ErrorSource.connection,
        technical: technical,
      );
    }
    if (error is chopper.Response) {
      final status = error.statusCode;
      final message = switch (status) {
        401 || 403 => GlobalSnackbar.requireL10n.errorHttp401,
        404 => GlobalSnackbar.requireL10n.errorHttp404,
        408 || 504 => GlobalSnackbar.requireL10n.errorHttp408,
        429 => GlobalSnackbar.requireL10n.errorHttp429,
        >= 500 => GlobalSnackbar.requireL10n.errorHttp500,
        _ => GlobalSnackbar.requireL10n.errorHttpOther(status),
      };
      return (message: message, source: ErrorSource.connection, technical: "HTTP $status ${error.error ?? ""}".trim());
    }
    if (error is FileSystemException) {
      final os = error.osError?.errorCode;
      final message = os == 28 || os == 112
          ? GlobalSnackbar.requireL10n.errorDiskFull
          : os == 13 || os == 1 || os == 5
          ? GlobalSnackbar.requireL10n.errorPermission
          : GlobalSnackbar.requireL10n.errorFile;
      return (message: message, source: ErrorSource.device, technical: technical);
    }
    if (error is FormatException) {
      return (
        message: GlobalSnackbar.requireL10n.errorUnexpectedResponse,
        source: ErrorSource.connection,
        technical: technical,
      );
    }
    return (message: GlobalSnackbar.requireL10n.errorGeneric, source: ErrorSource.unknown, technical: technical);
  }

  static String report(Logger logger, String what, Object error, [StackTrace? stack]) {
    final d = describe(error);
    logger.severe("$what failed [${d.source.name}]: ${d.technical}", error, stack);
    return d.message;
  }

  static String reportGlobal(String what, Object error, [StackTrace? stack]) => report(_log, what, error, stack);
}

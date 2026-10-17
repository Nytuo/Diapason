import 'dart:async';
import 'dart:io';

import 'package:chopper/chopper.dart' as chopper;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

enum ErrorSource { connection, uploader, ytdlp, device, unknown }

extension ErrorSourceLabel on ErrorSource {
  String get label => switch (this) {
    ErrorSource.connection => "Connection",
    ErrorSource.uploader => "Your uploader",
    ErrorSource.ytdlp => "yt-dlp",
    ErrorSource.device => "This device",
    ErrorSource.unknown => "Unexpected",
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
      return (
        message: "That took too long and was stopped. Check your connection and try again.",
        source: ErrorSource.connection,
        technical: technical,
      );
    }
    if (error is HandshakeException || error is TlsException) {
      return (
        message: "A secure connection couldn't be set up. The server's certificate may be invalid or expired.",
        source: ErrorSource.connection,
        technical: technical,
      );
    }
    if (error is SocketException) {
      final text = error.toString().toLowerCase();
      final message = text.contains("failed host lookup") || text.contains("nodename nor servname")
          ? "Couldn't find that server. Check the address and your internet connection."
          : text.contains("connection refused")
          ? "The server refused the connection — is it running, and is the port right?"
          : "Couldn't connect to the server. Check your network.";
      return (message: message, source: ErrorSource.connection, technical: technical);
    }
    if (error is http.ClientException) {
      return (
        message: "The connection to the server was interrupted. Check your network and try again.",
        source: ErrorSource.connection,
        technical: technical,
      );
    }
    if (error is chopper.Response) {
      final status = error.statusCode;
      final message = switch (status) {
        401 || 403 => "The server didn't accept your login. Sign in again or check your permissions.",
        404 => "The server couldn't find that item. It may have been moved or deleted.",
        408 || 504 => "The server took too long to answer.",
        429 => "The server is asking you to slow down. Try again in a moment.",
        >= 500 => "The server had a problem handling that request.",
        _ => "The server rejected that request (HTTP $status).",
      };
      return (message: message, source: ErrorSource.connection, technical: "HTTP $status ${error.error ?? ""}".trim());
    }
    if (error is FileSystemException) {
      final os = error.osError?.errorCode;
      final message = os == 28 || os == 112
          ? "There isn't enough free space on this device."
          : os == 13 || os == 1 || os == 5
          ? "Diapason doesn't have permission to use that file or folder."
          : "A file on this device couldn't be read or written.";
      return (message: message, source: ErrorSource.device, technical: technical);
    }
    if (error is FormatException) {
      return (
        message: "The server sent something unexpected. Is the address pointing at the right service?",
        source: ErrorSource.connection,
        technical: technical,
      );
    }
    return (
      message: "Something went wrong. If it keeps happening, check the logs from Settings.",
      source: ErrorSource.unknown,
      technical: technical,
    );
  }

  static String report(Logger logger, String what, Object error, [StackTrace? stack]) {
    final d = describe(error);
    logger.warning("$what failed [${d.source.name}]: ${d.technical}", error, stack);
    return d.message;
  }

  static String reportGlobal(String what, Object error, [StackTrace? stack]) => report(_log, what, error, stack);
}

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// An HTTP client that gives up connecting after [connectTimeout].
/// See `connect_timeout_client_web.dart` for the browser build.
http.Client connectTimeoutClient(Duration connectTimeout) =>
    IOClient(HttpClient()..connectionTimeout = connectTimeout);

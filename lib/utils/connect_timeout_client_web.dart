import 'package:http/http.dart' as http;

/// Web build of `connect_timeout_client.dart`: the browser owns connection
/// handling (dart:io's HttpClient doesn't exist there), so this is a plain
/// fetch-backed client and the connect timeout is left to the browser.
http.Client connectTimeoutClient(Duration connectTimeout) => http.Client();

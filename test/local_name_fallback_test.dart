import 'dart:io';

import 'package:diapason/services/uploader/local_name_fallback_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUp(LocalNameFallbackClient.resolved.clear);

  test("a .local name that doesn't resolve is retried at the address Bonjour gives", () async {
    final seen = <Uri>[];
    final hosts = <String?>[];
    final client = LocalNameFallbackClient(
      MockClient((request) async {
        seen.add(request.url);
        hosts.add(request.headers["Host"]);
        if (request.url.host == "kakarot.local") {
          throw const SocketException("Failed host lookup: 'kakarot.local'");
        }
        return http.Response("ok", 200);
      }),
      serviceType: "_diapason-uploader._tcp",
      resolve: (host) async => InternetAddress("192.168.1.100"),
    );

    final response = await client.get(Uri.parse("http://kakarot.local:8688/api/v1/capabilities"));
    expect(response.statusCode, 200);
    expect(seen.last.toString(), "http://192.168.1.100:8688/api/v1/capabilities");
    expect(hosts.last, "kakarot.local:8688");

    // Later requests, and URLs handed elsewhere, go straight to the address.
    await client.get(Uri.parse("http://kakarot.local:8688/api/v1/exists?hash=x"));
    expect(seen.last.host, "192.168.1.100");
    expect(LocalNameFallbackClient.rewrite(Uri.parse("http://kakarot.local:8688/a")).host, "192.168.1.100");
    expect(LocalNameFallbackClient.rewrite(Uri.parse("https://kakarot.local:8688/a")).host, "kakarot.local");
  });

  test("other failures and other names are left alone", () async {
    final client = LocalNameFallbackClient(
      MockClient((request) async => throw const SocketException("Connection refused")),
      serviceType: "_x._tcp",
      resolve: (host) async => fail("should not resolve"),
    );
    expect(() => client.get(Uri.parse("http://kakarot.local:8688/")), throwsA(isA<SocketException>()));
    expect(() => client.get(Uri.parse("http://example.com/")), throwsA(isA<SocketException>()));
  });
}

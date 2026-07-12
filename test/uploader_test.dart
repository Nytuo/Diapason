import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group("network policy", () {
    // The point of the local policy is that a mistyped address cannot quietly
    // ship someone's music library to a stranger.
    const local = UploaderNetworkPolicy.local;

    test("private and loopback addresses are local", () {
      for (final url in [
        "http://localhost:8080",
        "http://127.0.0.1:8080",
        "http://10.0.0.5",
        "http://192.168.1.10:8080",
        "http://172.16.0.1",
        "http://172.31.255.254",
        "http://nas.local:8080",
        "http://[::1]:8080",
      ]) {
        expect(UploaderClient.isAllowed(url, local), isTrue, reason: url);
      }
    });

    test("public addresses are not local", () {
      for (final url in [
        "https://example.com",
        "http://8.8.8.8",
        // Just outside the private range — the classic off-by-one.
        "http://172.15.0.1",
        "http://172.32.0.1",
        // Looks private, isn't.
        "http://192.169.1.1",
      ]) {
        expect(UploaderClient.isAllowed(url, local), isFalse, reason: url);
      }
    });

    test("a hostname that merely contains a private address is not local", () {
      // Would pass a naive "contains" check.
      expect(UploaderClient.isAllowed("http://192.168.1.10.evil.com", local), isFalse);
    });

    test("the internet policy allows anything", () {
      expect(UploaderClient.isAllowed("https://example.com", UploaderNetworkPolicy.internet), isTrue);
      expect(UploaderClient.isAllowed("http://192.168.1.10", UploaderNetworkPolicy.internet), isTrue);
    });

    test("an unparseable address is refused", () {
      expect(UploaderClient.isAllowed("not a url", local), isFalse);
      expect(UploaderClient.isAllowed("", local), isFalse);
    });
  });

  test("policy names round-trip, and an unknown name falls back to local", () {
    expect(UploaderNetworkPolicy.fromName("internet"), UploaderNetworkPolicy.internet);
    expect(UploaderNetworkPolicy.fromName("local"), UploaderNetworkPolicy.local);
    // Safe default: never silently widen to the internet.
    expect(UploaderNetworkPolicy.fromName("nonsense"), UploaderNetworkPolicy.local);
  });
}

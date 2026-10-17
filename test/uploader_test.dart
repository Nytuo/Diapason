import 'package:diapason/services/uploader/local_file_upload.dart';
import 'package:diapason/services/uploader/uploader_client.dart';
import 'package:diapason/services/youtube/yt_entry.dart';
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

    test("the internet policy allows https anywhere and http on private networks", () {
      expect(UploaderClient.isAllowed("https://example.com", UploaderNetworkPolicy.internet), isTrue);
      expect(UploaderClient.isAllowed("http://192.168.1.10", UploaderNetworkPolicy.internet), isTrue);
    });

    test("plain http is never allowed to a public host, whatever the policy", () {
      // The bearer token and the audio would cross the internet in the clear.
      for (final url in ["http://example.com", "http://8.8.8.8:8688", "http://music.example.com/uploader"]) {
        expect(UploaderClient.isAllowed(url, UploaderNetworkPolicy.internet), isFalse, reason: url);
        expect(UploaderClient.blockReason(url, UploaderNetworkPolicy.internet), contains("https"), reason: url);
      }
    });

    test("overlay networks count as private, so no https is needed", () {
      for (final url in [
        "http://100.101.102.103:8688", // Tailscale CGNAT
        "http://diapason.tail1234.ts.net:8688",
        "http://nas.home.arpa",
        "http://[fd7a:115c:a1e0::1]:8688",
      ]) {
        expect(UploaderClient.isAllowed(url, local), isTrue, reason: url);
      }
      expect(UploaderClient.isPrivateHost("100.63.0.1"), isFalse);
      expect(UploaderClient.isPrivateHost("100.128.0.1"), isFalse);
    });

    test("plain http to a public-looking name needs the explicit 'already secure' opt-in", () {
      const url = "http://music.example.com:8688";
      expect(UploaderClient.isAllowed(url, UploaderNetworkPolicy.internet), isFalse);
      expect(UploaderClient.isAllowed(url, UploaderNetworkPolicy.internet, allowInsecure: true), isTrue);
      // The opt-in never overrides the local-only policy.
      expect(UploaderClient.isAllowed(url, local, allowInsecure: true), isFalse);
    });

    test("only http(s) addresses are accepted", () {
      for (final url in ["ftp://192.168.1.10", "file:///etc/passwd", "192.168.1.10:8688", "javascript:alert(1)"]) {
        expect(UploaderClient.isAllowed(url, UploaderNetworkPolicy.internet), isFalse, reason: url);
      }
    });

    test("link-local and unique-local IPv6 count as private", () {
      expect(UploaderClient.isPrivateHost("fe80::1"), isTrue);
      expect(UploaderClient.isPrivateHost("fd12:3456::1"), isTrue);
      expect(UploaderClient.isPrivateHost("2001:4860:4860::8888"), isFalse);
    });

    test("an unparseable address is refused", () {
      expect(UploaderClient.isAllowed("not a url", local), isFalse);
      expect(UploaderClient.isAllowed("", local), isFalse);
    });
  });

  localUploadTests();

  test("policy names round-trip, and an unknown name falls back to local", () {
    expect(UploaderNetworkPolicy.fromName("internet"), UploaderNetworkPolicy.internet);
    expect(UploaderNetworkPolicy.fromName("local"), UploaderNetworkPolicy.local);
    // Safe default: never silently widen to the internet.
    expect(UploaderNetworkPolicy.fromName("nonsense"), UploaderNetworkPolicy.local);
  });
}

void localUploadTests() {
  group("file name tags", () {
    test("splits Artist - Title", () {
      final tags = LocalFileUpload.guessTags("/music/Daft Punk - One More Time.mp3");
      expect(tags.artist, "Daft Punk");
      expect(tags.title, "One More Time");
    });

    test("keeps later dashes in the title", () {
      final tags = LocalFileUpload.guessTags("/x/Artist - Song - Live.flac");
      expect(tags.artist, "Artist");
      expect(tags.title, "Song - Live");
    });

    test("a hyphen inside a word is not a separator", () {
      final tags = LocalFileUpload.guessTags("/x/Semi-Charmed Life.mp3");
      expect(tags.artist, "");
      expect(tags.title, "Semi-Charmed Life");
    });
  });

  test("audio extensions offered to the picker match what the server accepts", () {
    expect(UploaderClient.audioExtensions, containsAll(["mp3", "m4a", "flac", "opus"]));
    expect(UploaderClient.audioExtensions, isNot(contains("html")));
  });

  test("proxy entries parse", () {
    final entry = YtEntry.fromJson({"id": "dQw4w9WgXcQ", "title": "T", "artist": "A", "durationSecs": 212});
    expect(entry.id, "dQw4w9WgXcQ");
    expect(entry.durationSecs, 212);
  });
}

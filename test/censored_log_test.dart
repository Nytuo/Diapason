import 'package:diapason/services/censored_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  test("credentials in URL query strings never reach the log", () {
    final record = LogRecord(
      Level.INFO,
      "Found 0 chapters for 'https://music.example.com/rest/download.view?u=arnaud&t=8051492efa67ce2914a7&s=4357ba417e2f&v=1.16.1&c=Diapason&id=sub-1'"
      " and https://plex.example.com/library?X-Plex-Token=abc123&x=1 and https://x.example/p?api_key=K&p=hunter2",
      "test",
    );
    final text = record.censoredMessage;
    for (final secret in ["8051492efa67ce2914a7", "4357ba417e2f", "abc123", "api_key=K&", "hunter2"]) {
      expect(text, isNot(contains(secret)), reason: secret);
    }
    // Harmless parameters stay, so the log is still useful.
    expect(text, contains("id=sub-1"));
    expect(text, contains("c=Diapason"));
    expect(text, contains("t=CENSORED"));
  });
}

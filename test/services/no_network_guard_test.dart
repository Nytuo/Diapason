import 'package:diapason/services/no_network_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("loopback hosts stay reachable", () {
    expect(NoNetworkGuard.isLoopback("localhost"), isTrue);
    expect(NoNetworkGuard.isLoopback("app.localhost"), isTrue);
    expect(NoNetworkGuard.isLoopback("127.0.0.1"), isTrue);
    expect(NoNetworkGuard.isLoopback("[::1]"), isTrue);
    expect(NoNetworkGuard.isLoopback("::1"), isTrue);
  });

  test("other hosts are not loopback", () {
    expect(NoNetworkGuard.isLoopback("192.168.1.10"), isFalse);
    expect(NoNetworkGuard.isLoopback("music.example.com"), isFalse);
    expect(NoNetworkGuard.isLoopback("nas.local"), isFalse);
  });

  test("nothing is blocked while settings aren't loaded", () {
    expect(NoNetworkGuard.blocks(Uri.parse("https://music.example.com")), isFalse);
  });
}

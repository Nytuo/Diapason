import 'package:diapason/services/connect/connect_mdns.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a service found on the network is read from the platform map', () {
    final s = MdnsService.fromMap({
      'name': 'Kitchen',
      'host': '192.168.1.9',
      'port': 4242,
      'txt': {'token': 'abc'},
    });
    expect(s.name, 'Kitchen');
    expect(s.host, '192.168.1.9');
    expect(s.port, 4242);
    expect(s.txt, {'token': 'abc'});

    final bare = MdnsService.fromMap({});
    expect(bare.name, '');
    expect(bare.host, isNull);
    expect(bare.txt, isEmpty);
  });

  group('Bonjour on tvOS', () {
    const channel = MethodChannel('fr.nytuo.diapason/appletv_bonjour');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );

    test('announcing and stopping go to the native side with the details', () async {
      final mdns = TvOsMdns();
      await mdns.register(name: 'Living room', type: '_diapason-connect._tcp', port: 5000, txt: {'token': 't'});
      await mdns.unregister();

      expect(calls.map((c) => c.method), ['register', 'unregister']);
      expect(calls.first.arguments, {
        'name': 'Living room',
        'type': '_diapason-connect._tcp',
        'port': 5000,
        'txt': {'token': 't'},
      });
    });

    test('browsing relays what the native side finds, until it is stopped', () async {
      final mdns = TvOsMdns();
      List<MdnsService>? latest;
      await mdns.startBrowse('_diapason-connect._tcp', (services) => latest = services);
      expect(calls.single.method, 'startBrowse');
      expect(calls.single.arguments, {'type': '_diapason-connect._tcp'});

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('services', [
            {
              'name': 'Phone',
              'host': '10.0.0.4',
              'port': 99,
              'txt': {'token': 'x'},
            },
          ]),
        ),
        (_) {},
      );
      expect(latest!.single.name, 'Phone');
      expect(latest!.single.txt['token'], 'x');

      await mdns.stopBrowse();
      latest = null;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('services', [])),
        (_) {},
      );
      expect(latest, isNull, reason: 'nothing is delivered after stopping');
      expect(calls.last.method, 'stopBrowse');
    });
  });
}

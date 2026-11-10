import 'dart:async';
import 'dart:typed_data';

import 'package:diapason/services/spectrum_source.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSource implements SpectrumSource {
  _FakeSource(this.sessionId, this.fps);

  final int? sessionId;
  final int fps;
  final _controller = StreamController<SpectrumFrame>.broadcast();
  bool running = false;

  @override
  Stream<SpectrumFrame> get frames => _controller.stream;

  @override
  Future<bool> start() async => running = true;

  @override
  Future<void> stop() async => running = false;

  void emit() => _controller.add(SpectrumFrame(Float32List(4), 44100));
}

/// Several visualizers (player screen, desktop bar, settings preview) share one native spectrum source.
void main() {
  late List<_FakeSource> created;
  late SpectrumHub hub;

  setUp(() {
    created = [];
    hub = SpectrumHub.forTest(({int? androidSessionId, required int fps}) {
      final source = _FakeSource(androidSessionId, fps);
      created.add(source);
      return source;
    });
  });

  test('two visualizers share one source, which stops only when both are gone', () async {
    final a = Object(), b = Object();
    expect(await hub.acquire(a, fps: 30), isTrue);
    expect(await hub.acquire(b, fps: 30), isTrue);
    expect(created, hasLength(1));

    var received = 0;
    final subscription = hub.frames.listen((_) => received++);
    created.single.emit();
    await Future<void>.delayed(Duration.zero);
    expect(received, 1);

    await hub.release(a);
    expect(created.single.running, isTrue);
    await hub.release(b);
    expect(created.single.running, isFalse);
    expect(hub.isRunning, isFalse);
    await subscription.cancel();
  });

  test('a new session or frame rate restarts the source', () async {
    final a = Object();
    await hub.acquire(a, androidSessionId: 1, fps: 30);
    await hub.acquire(a, androidSessionId: 2, fps: 30);
    expect(created, hasLength(2));
    expect(created.first.running, isFalse);
    expect(created.last.sessionId, 2);
  });

  test('releasing an unknown holder changes nothing', () async {
    final a = Object();
    await hub.acquire(a, fps: 30);
    await hub.release(Object());
    expect(hub.isRunning, isTrue);
  });

  test('no source on this platform means no frames', () async {
    final none = SpectrumHub.forTest(({int? androidSessionId, required int fps}) => null);
    expect(await none.acquire(Object(), fps: 30), isFalse);
    expect(none.isRunning, isFalse);
  });
}

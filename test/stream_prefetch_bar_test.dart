import 'package:diapason/components/stream_prefetch_bar.dart';
import 'package:diapason/services/stream_cache_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

/// A YouTube track plays from its first bytes while the rest is still arriving.
/// Until it has all landed, seeking past the end of it will not work — so the bar
/// says what is still coming, and gets out of the way when it has.
void main() {
  late StreamCacheService cache;

  setUp(() {
    cache = StreamCacheService();
    GetIt.instance.registerSingleton<StreamCacheService>(cache);
  });

  tearDown(() => GetIt.instance.reset());

  Future<void> pump(WidgetTester tester) =>
      tester.pumpWidget(const MaterialApp(home: Scaffold(body: StreamPrefetchBar())));

  testWidgets("shows nothing at all when nothing is being cached", (tester) async {
    await pump(tester);

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining("Caching"), findsNothing);
  });

  testWidgets("names the track and how much of it has arrived", (tester) async {
    cache.prefetch.value = const StreamPrefetch(title: "Manalan Mailla", fraction: 0.5);
    await pump(tester);

    expect(find.text("Caching Manalan Mailla…"), findsOneWidget);
    expect(find.text("50%"), findsOneWidget);

    final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, 0.5);
  });

  testWidgets("gets out of the way once the track has fully landed", (tester) async {
    cache.prefetch.value = const StreamPrefetch(title: "Song", fraction: 0.1);
    await pump(tester);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    cache.prefetch.value = null;
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}

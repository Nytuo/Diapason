import 'package:diapason/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {


  testWidgets('the startup error screen renders without services', (tester) async {
    await tester.pumpWidget(FinampErrorApp(error: StateError('boom'), trace: StackTrace.current));
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.textContaining('boom'), findsWidgets);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:diapason/main.dart';

void main() {
  testWidgets('app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const DiapasonApp());
    expect(find.text('Running on Apple TV'), findsOneWidget);
  });
}

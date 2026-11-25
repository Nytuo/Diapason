import 'dart:ui' as ui;

import 'package:diapason/screens/desktop/desktop_ambient_background.dart';
import 'package:diapason/screens/desktop/desktop_home.dart';
import 'package:diapason/screens/desktop/desktop_kit.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dark = ColorScheme.fromSeed(seedColor: Colors.deepOrange, brightness: Brightness.dark);
  final light = ColorScheme.fromSeed(seedColor: Colors.deepOrange);

  group('DesktopAmbientMode', () {
    test('parses stored names, falling back to the blurred cover', () {
      expect(DesktopAmbientMode.fromName('off'), DesktopAmbientMode.off);
      expect(DesktopAmbientMode.fromName('colors'), DesktopAmbientMode.colors);
      expect(DesktopAmbientMode.fromName('cover'), DesktopAmbientMode.cover);
      expect(DesktopAmbientMode.fromName('nonsense'), DesktopAmbientMode.cover);
    });
  });

  group('DesktopPalette', () {
    test('pages paint transparent over the ambient background, opaque without it', () {
      expect(DesktopPalette.fromScheme(dark, ambient: true).bg, Colors.transparent);
      expect(DesktopPalette.fromScheme(dark).bg.a, 1.0);
      expect(DesktopPalette.fromScheme(light).bg.a, 1.0);
    });

    test('chrome and panels turn translucent only with the ambient background', () {
      for (final scheme in [dark, light]) {
        final plain = DesktopPalette.fromScheme(scheme);
        final ambient = DesktopPalette.fromScheme(scheme, ambient: true);
        expect(plain.chrome.a, 1.0);
        expect(plain.panel.a, 1.0);
        expect(ambient.chrome.a, lessThan(1.0));
        expect(ambient.panel.a, lessThan(1.0));
        expect(ambient.window.a, 1.0, reason: 'the bottom layer is opaque');
      }
    });

    test('reduce effects zeroes decorative motion', () {
      const d = Duration(milliseconds: 300);
      expect(DesktopPalette.fromScheme(dark).motion(d), d);
      expect(DesktopPalette.fromScheme(dark, reduceEffects: true).motion(d), Duration.zero);
    });

    test('equality follows the tokens that matter', () {
      expect(DesktopPalette.fromScheme(dark), DesktopPalette.fromScheme(dark));
      expect(DesktopPalette.fromScheme(dark) == DesktopPalette.fromScheme(dark, ambient: true), isFalse);
      expect(DesktopPalette.fromScheme(dark) == DesktopPalette.fromScheme(light), isFalse);
    });
  });

  test('a cover is blurred into a small bitmap', () async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 64, 128), Paint()..color = Colors.red);
    canvas.drawRect(const Rect.fromLTWH(64, 0, 64, 128), Paint()..color = Colors.blue);
    final source = await recorder.endRecording().toImage(128, 128);
    final blurred = await DesktopBlurredCoverCache.blurImage(source, side: 32, sigma: 4);
    expect(blurred.width, 32);
    expect(blurred.height, 32);
    final bytes = (await blurred.toByteData())!;
    // The middle column mixes both halves.
    final mid = (16 * 32 + 16) * 4;
    expect(bytes.getUint8(mid), inInclusiveRange(40, 215));
    expect(bytes.getUint8(mid + 2), inInclusiveRange(40, 215));
    source.dispose();
    blurred.dispose();
  });

  test('genre colours are stable and differ between genres', () {
    expect(DesktopGenreTile.colorFor('Rock'), DesktopGenreTile.colorFor('rock'));
    expect(DesktopGenreTile.colorFor('Rock') == DesktopGenreTile.colorFor('Jazz'), isFalse);
  });

  testWidgets('panels and section headers build from the theme scope', (tester) async {
    var next = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopThemeScope(
          palette: DesktopPalette.fromScheme(dark, ambient: true),
          child: Scaffold(
            body: DesktopPanel(
              child: DesktopSectionHeader(
                title: 'Recently added',
                showPaging: true,
                nextTooltip: 'Next',
                onNext: () => next++,
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Recently added'), findsOneWidget);
    await tester.tap(find.byTooltip('Next'));
    expect(next, 1);
  });
}

import 'dart:async';
import 'dart:math' show Random;

import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  installHarness();

  group(
    'poking at every screen',
    () {
      final avoid = RegExp(
        r'log ?out|sign ?out|delete|remove|clear|reset|erase|wipe|install|update|existing|choose|pick|browse|folder|'
        r'export|import|share|launch|quit|exit|scan|cast|connect|language|source|uploader|certificate|authorize|'
        r'play|shuffle|radio|mix|surprise|random|queue|resume|next|previous|download|favorite|favourite|'
        r'mini|full ?screen|collapse|expand|window|compact|zoom|maximi|theme',
        caseSensitive: false,
      );

      String labelOf(Element element) {
        final parts = <String>[];
        void visit(Element e) {
          final w = e.widget;
          if (w is Text && w.data != null) parts.add(w.data!);
          if (w is Tooltip && w.message != null) parts.add(w.message!);
          if (w is Icon && w.semanticLabel != null) parts.add(w.semanticLabel!);
          e.visitChildren(visit);
        }

        visit(element);
        return parts.join(' ');
      }

      bool tappable(Widget w) =>
          w is InkWell ||
          w is IconButton ||
          w is ListTile ||
          w is Switch ||
          w is Checkbox ||
          w is Radio ||
          w is ChoiceChip ||
          w is FilterChip ||
          w is ActionChip ||
          w is FilledButton ||
          w is TextButton ||
          w is OutlinedButton ||
          w is ElevatedButton ||
          w is PopupMenuButton ||
          w is Slider ||
          w is ExpansionTile;

      Route<dynamic> topRoute() {
        late Route<dynamic> top;
        GlobalSnackbar.navigatorState!.popUntil((r) {
          top = r;
          return true;
        });
        return top;
      }

      Future<void> watched(Future<void> Function() body) async {
        final done = Completer<void>();
        runZonedGuarded(() async {
          try {
            await body();
            done.complete();
          } catch (e, stack) {
            done.completeError(e, stack);
          }
        }, (e, stack) => print('UNCAUGHT while poking: $e\n$stack'));
        await done.future;
      }

      Future<void> _poke(WidgetTester tester, {required int taps, required int seed}) async {
        final random = Random(seed);
        final start = topRoute();
        var done = 0;
        var depth = 0;
        for (var i = 0; i < taps * 3 && done < taps; i++) {
          final size = tester.view.physicalSize / tester.view.devicePixelRatio;
          final screen = Offset.zero & size;
          final candidates = find.byWidgetPredicate(tappable).evaluate().where((e) {
            final box = e.renderObject;
            if (box is! RenderBox || !box.attached || !box.hasSize || box.size.isEmpty) return false;
            final rect = box.localToGlobal(Offset.zero) & box.size;
            return screen.contains(rect.center) && !avoid.hasMatch(labelOf(e));
          }).toList();
          if (candidates.isEmpty) break;
          final target = candidates[random.nextInt(candidates.length)];
          final center =
              (target.renderObject! as RenderBox).localToGlobal(Offset.zero) +
              (target.renderObject! as RenderBox).size.center(Offset.zero);
          done++;
          switch (random.nextInt(10)) {
            case 0:
              await tester.longPressAt(center);
            case 1:
              await tester.tapAt(center, buttons: kSecondaryButton);
            default:
              await tester.tapAt(center);
          }
          for (var f = 0; f < 4; f++) {
            await tester.pump(const Duration(milliseconds: 120));
          }

          if (!identical(topRoute(), start)) {
            depth++;
            if (depth > 2 || random.nextInt(3) != 0) {
              GlobalSnackbar.navigatorState!.popUntil((r) => identical(r, start) || r.isFirst);
              depth = 0;
              await tester.settle();
            }
          }
        }
        GlobalSnackbar.navigatorState!.popUntil((r) => identical(r, start) || r.isFirst);
        FinampSetters.setLocale(DefaultSettings.locale);
        await tester.settle();
      }

      Future<void> poke(WidgetTester tester, {required int taps, required int seed}) =>
          watched(() => _poke(tester, taps: taps, seed: seed));

      for (final view in [
        'Home',
        'Albums',
        'Artists',
        'Songs',
        'Genres',
        'Playlists',
        'Road trip',
        'Smart',
        'Discover',
      ]) {
        testApp('the $view view survives being poked', (tester) async {
          await launch(tester);
          await tester.waitFor(library, seconds: 30);

          if (find.text(view).evaluate().isNotEmpty) await tester.tap(find.text(view).first, warnIfMissed: false);
          await tester.settle();
          await poke(tester, taps: 12, seed: view.hashCode);
        }, timeout: const Timeout(Duration(seconds: 60)));
      }

      testApp('an album page survives being poked', (tester) async {
        await launch(tester);
        await openAlbums(tester);
        await tester.tap(find.text('First Album').first, warnIfMissed: false);
        await tester.waitFor(find.text('Opening'), seconds: 20);
        await poke(tester, taps: 14, seed: 7);
      }, timeout: const Timeout(Duration(seconds: 60)));

      for (final entry in screenRoutes.entries) {
        if ({
          'SourcesSettingsScreen',
          'UploaderSettingsScreen',
          'LanguageSelectionScreen',
          'ImportScreen',
          'CastScreen',
          'ConnectScreen',
        }.contains(entry.key))
          continue;
        testApp('${entry.key} survives being poked', (tester) async {
          await launch(tester);
          GlobalSnackbar.navigatorState!.pushNamed(entry.value);
          await tester.settle();
          await poke(tester, taps: 10, seed: entry.key.hashCode);
          GlobalSnackbar.navigatorState?.popUntil((r) => r.isFirst);
          await tester.settle();
        }, timeout: const Timeout(Duration(seconds: 60)));
      }
    },
    skip: !const bool.fromEnvironment('EXPLORE')
        ? 'opt in with tools/test.sh explore: random presses can leave the app in a broken state, failing the tests after it'
        : null,
  );
}

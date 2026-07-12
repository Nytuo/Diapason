import 'package:diapason/screens/ipod/ipod_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group("iPod menu screens", () {
    test("selection moves with the wheel and stops at the ends", () {
      final screen = IpodScreen(
        title: "Albums",
        rows: [
          for (var i = 0; i < 3; i++) IpodRow(title: "Row $i", action: const IpodNowPlayingAction()),
        ],
      );

      screen.select(2);
      expect(screen.selection, 2);

      // The wheel spins freely; the list must not run off either end.
      screen.select((screen.selection + 5).clamp(0, screen.rows.length - 1));
      expect(screen.selection, 2);

      screen.select((screen.selection - 9).clamp(0, screen.rows.length - 1));
      expect(screen.selection, 0);
    });

    test("a screen with a loader starts empty and loads on demand", () async {
      var loads = 0;
      final screen = IpodScreen(
        title: "Artists",
        loader: () async {
          loads++;
          return [const IpodRow(title: "Bowie", action: IpodNowPlayingAction())];
        },
      );

      expect(screen.rows, isEmpty);

      await screen.loadIfNeeded();
      expect(screen.rows.single.title, "Bowie");
      expect(loads, 1);

      // Already loaded: descending back into it must not refetch.
      await screen.loadIfNeeded();
      expect(loads, 1);
    });

    test("Now Playing never loads rows", () async {
      var loaded = false;
      final screen = IpodScreen(
        title: "Now Playing",
        isNowPlaying: true,
        loader: () async {
          loaded = true;
          return const [];
        },
      );

      await screen.loadIfNeeded();

      expect(loaded, isFalse);
    });

    test("notifies when the selection changes, and only then", () {
      var notifications = 0;
      final screen = IpodScreen(
        title: "Songs",
        rows: [
          for (var i = 0; i < 3; i++) IpodRow(title: "Row $i", action: const IpodNowPlayingAction()),
        ],
      )..addListener(() => notifications++);

      screen.select(1);
      expect(notifications, 1);

      // The wheel can report the same detent twice; that must not repaint.
      screen.select(1);
      expect(notifications, 1);
    });
  });

  group("InterfaceMode", () {
    test("round-trips by name, falling back to modern", () {
      expect(InterfaceMode.fromName("ipod"), InterfaceMode.ipod);
      expect(InterfaceMode.fromName("modern"), InterfaceMode.modern);
      // A setting written by a future version must not strand the user in a
      // shell they cannot leave.
      expect(InterfaceMode.fromName("something-else"), InterfaceMode.modern);
    });

    test("labels read as the iOS app's do", () {
      expect(InterfaceMode.ipod.label, "iPod Classic");
      expect(InterfaceMode.modern.label, "Modern");
    });
  });
}

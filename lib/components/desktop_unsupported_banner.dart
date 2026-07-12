import 'package:diapason/utils/platform_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Warns that the Flutter build of Diapason is not supported on desktop, where
/// the Tauri app (github.com/Nytuo/Diapason) is the one that ships. The app
/// still runs normally — this only informs, it never blocks.
class DesktopUnsupportedBanner extends StatefulWidget {
  const DesktopUnsupportedBanner({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopUnsupportedBanner> createState() => _DesktopUnsupportedBannerState();
}

class _DesktopUnsupportedBannerState extends State<DesktopUnsupportedBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (!isDesktop || _dismissed) return widget.child;

    final theme = Theme.of(context);
    final background = theme.colorScheme.errorContainer;
    final foreground = theme.colorScheme.onErrorContainer;

    return Column(
      children: [
        Material(
          color: background,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                children: [
                  Icon(TablerIcons.alert_triangle, color: foreground, size: 20.0),
                  const SizedBox(width: 12.0),
                  Expanded(
                    child: Text(
                      "Desktop is unsupported. This build targets phones, tablets and TV: features are missing here, "
                      "there are no updates, and bugs will not be fixed. Use the desktop app instead.",
                      style: theme.textTheme.bodySmall?.copyWith(color: foreground),
                    ),
                  ),
                  const SizedBox(width: 8.0),
                  TextButton(
                    onPressed: () => setState(() => _dismissed = true),
                    style: TextButton.styleFrom(foregroundColor: foreground),
                    child: const Text("Dismiss"),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}

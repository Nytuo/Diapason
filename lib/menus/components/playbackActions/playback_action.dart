import 'package:diapason/screens/desktop/desktop_router.dart';
import 'package:diapason/services/feedback_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

class PlaybackAction extends ConsumerWidget {
  const PlaybackAction({
    super.key,
    required this.icon,
    this.value,
    required this.onPressed,
    required this.label,
    required this.iconColor,
    this.onLongPress,
    this.enabled = true,
    this.addShuffleIcon = false,
    this.compactLayout = false,
  });

  final IconData icon;
  final String? value;
  final void Function() onPressed;
  final void Function()? onLongPress;
  final String label;
  final Color iconColor;
  final bool enabled;
  final bool addShuffleIcon;
  final bool compactLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final double mainSize = 28;
    final double badgeSize = mainSize * 0.5;

    final iconWidget = SizedBox(
      width: mainSize,
      height: mainSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(
            child: Icon(
              icon,
              color: enabled ? iconColor : iconColor.withValues(alpha: 0.5),
              size: mainSize,
              weight: 1.0,
            ),
          ),
          if (addShuffleIcon)
            Positioned(
              left: -8,
              right: 30,
              child: Icon(
                TablerIcons.arrows_shuffle,
                size: badgeSize,
                color: enabled ? iconColor : iconColor.withValues(alpha: 0.5),
              ),
            ),
        ],
      ),
    );

    if (DesktopRouter.isActive) {
      // Desktop: a pill with the icon beside its label, not the mobile icon-over-text button.
      final ink = Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black;
      return Flexible(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            child: TextButton.icon(
              style: TextButton.styleFrom(
                backgroundColor: ink.withValues(alpha: 0.08),
                foregroundColor: iconColor,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              onPressed: enabled
                  ? () {
                      FeedbackHelper.feedback(FeedbackType.selection);
                      onPressed();
                    }
                  : null,
              onLongPress: onLongPress,
              icon: Icon(icon, size: 18),
              label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            ),
          ),
        ),
      );
    }

    return Flexible(
      flex: 1,
      child: IconButton(
        icon: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: compactLayout ? 0 : 9,
          children: [
            Padding(
              padding: EdgeInsets.only(left: addShuffleIcon ? 10.0 : 0.0),
              child: iconWidget,
            ),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, height: 1.4, fontWeight: FontWeight.w300),
            ),
          ],
        ),
        onPressed: enabled
            ? () {
                FeedbackHelper.feedback(FeedbackType.selection);
                onPressed();
              }
            : null,
        onLongPress: onLongPress,
        visualDensity: VisualDensity.compact,
        padding: compactLayout
            ? EdgeInsets.only(top: 5.0, left: 4.0, right: 4.0, bottom: 5.0)
            : EdgeInsets.only(top: 10.0, left: 8.0, right: 8.0, bottom: 12.0),
      ),
    );
  }
}

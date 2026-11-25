import 'package:diapason/screens/desktop/desktop_album_detail.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:flutter/material.dart';

/// Frames a screen written for mobile (a `Scaffold` with an `AppBar`) so it
/// sits inside the desktop shell's content area: the app bar becomes a flat
/// page header in the desktop palette, the page background is the shell's,
/// and window insets are dropped (the shell already handles them).
class DesktopPageFrame extends StatelessWidget {
  const DesktopPageFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    final base = Theme.of(context);
    final titleStyle = TextStyle(color: p.textPrimary, fontSize: 18, fontWeight: FontWeight.w600);
    return Theme(
      data: base.copyWith(
        scaffoldBackgroundColor: p.bg,
        appBarTheme: base.appBarTheme.copyWith(
          backgroundColor: p.bg,
          surfaceTintColor: Colors.transparent,
          foregroundColor: p.textPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          toolbarHeight: 52,
          titleTextStyle: titleStyle,
          iconTheme: IconThemeData(color: p.textSecondary, size: 20),
          actionsIconTheme: IconThemeData(color: p.textSecondary, size: 20),
          shape: Border(bottom: BorderSide(color: p.borderSubtle)),
        ),
      ),
      child: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        removeBottom: true,
        removeLeft: true,
        removeRight: true,
        child: child,
      ),
    );
  }
}

/// The header row of a desktop page: back button (when there is somewhere to
/// go back to), a title and optional trailing actions.
class DesktopPageHeader extends StatelessWidget {
  const DesktopPageHeader({super.key, required this.title, this.subtitle, this.actions = const []});

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DesktopDetailBackButton(color: p.textSecondary),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.textPrimary, fontSize: 26, fontWeight: FontWeight.bold),
                      ),
                      if (subtitle != null) Text(subtitle!, style: TextStyle(color: p.textSecondary, fontSize: 13)),
                    ],
                  ),
                ),
                ...actions,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

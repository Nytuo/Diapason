import 'package:diapason/screens/desktop/desktop_router.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:window_manager/window_manager.dart';

class DesktopHeaderBar extends StatelessWidget {
  const DesktopHeaderBar({
    super.key,
    required this.title,
    required this.query,
    required this.onOpenSearch,
    required this.onClearSearch,
  });

  final String title;
  final String query;
  final VoidCallback onOpenSearch;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    // Sits inside the content panel, on its fill: no background of its own.
    return DragToMoveArea(
      child: SizedBox(
        height: DesktopMetrics.headerHeight,
        child: Padding(
          padding: const EdgeInsets.only(left: DesktopMetrics.pagePadding, right: 14, top: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: p.title),
              ),
              const SizedBox(width: 16),
              _SearchTrigger(query: query, onOpen: onOpenSearch, onClear: onClearSearch),
              const SizedBox(width: 8),
              IconButton(
                tooltip: "Settings",
                iconSize: 18,
                color: p.textSecondary,
                icon: const Icon(TablerIcons.settings),
                onPressed: () => DesktopRouter.pushNamed(context, SettingsScreen.routeName),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Looks like a search field but opens the command palette, so there is a single
/// place to search from. Shows the active query with a clear button.
class _SearchTrigger extends StatelessWidget {
  const _SearchTrigger({required this.query, required this.onOpen, required this.onClear});

  final String query;
  final VoidCallback onOpen;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    final active = query.trim().isNotEmpty;
    final mac = Theme.of(context).platform == TargetPlatform.macOS;
    return Tooltip(
      message: "Search (${mac ? '⌘' : 'Ctrl+'}K)",
      child: Material(
        color: p.surface,
        shape: StadiumBorder(side: BorderSide(color: active ? p.accent : p.borderSubtle)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onOpen,
          child: SizedBox(
            width: 300,
            height: 36,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(TablerIcons.search, size: 16, color: active ? p.accent : p.textTertiary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    active ? query : "Search or jump to…",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: active ? p.textPrimary : p.textTertiary, fontSize: 13),
                  ),
                ),
                if (active)
                  IconButton(
                    tooltip: "Clear search",
                    iconSize: 14,
                    visualDensity: VisualDensity.compact,
                    color: p.textSecondary,
                    icon: const Icon(TablerIcons.x),
                    onPressed: onClear,
                  )
                else
                  Container(
                    margin: const EdgeInsets.only(right: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      border: Border.all(color: p.border),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      mac ? "⌘K" : "Ctrl K",
                      style: TextStyle(color: p.textTertiary, fontSize: 10.5, fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

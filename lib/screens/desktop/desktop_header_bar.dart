import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

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
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: p.bg,
        border: Border(bottom: BorderSide(color: p.borderSubtle)),
      ),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(color: p.textPrimary, fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: -0.2),
          ),
          const Spacer(),
          _SearchTrigger(query: query, onOpen: onOpenSearch, onClear: onClearSearch),
          const SizedBox(width: 8),
          IconButton(
            tooltip: "Settings",
            iconSize: 18,
            color: p.textSecondary,
            icon: const Icon(TablerIcons.settings),
            onPressed: () => Navigator.of(context).pushNamed(SettingsScreen.routeName),
          ),
        ],
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
        shape: StadiumBorder(side: BorderSide(color: active ? p.accent : p.border)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onOpen,
          child: SizedBox(
            width: 300,
            height: 38,
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

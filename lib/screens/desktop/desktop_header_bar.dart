import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

class DesktopHeaderBar extends StatelessWidget {
  const DesktopHeaderBar({
    super.key,
    required this.title,
    required this.searchController,
    required this.onSearchChanged,
  });

  final String title;
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;

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
            style: TextStyle(
              color: p.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.bold,
              letterSpacing: -0.2,
            ),
          ),
          const Spacer(),
          SizedBox(
            width: 280,
            height: 38,
            child: TextField(
              controller: searchController,
              onChanged: onSearchChanged,
              style: TextStyle(color: p.textPrimary, fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: "Search your library…",
                hintStyle: TextStyle(color: p.textTertiary, fontSize: 13),
                prefixIcon: Icon(TablerIcons.search, size: 16, color: p.textTertiary),
                filled: true,
                fillColor: p.surface,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide(color: p.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide(color: p.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide(color: p.accent),
                ),
              ),
            ),
          ),
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

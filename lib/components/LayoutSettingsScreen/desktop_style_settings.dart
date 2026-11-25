import 'package:diapason/extensions/localizations.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The desktop shell's look: background behind the panels, big cover art,
/// reduce effects. Shown on desktop only.
class DesktopStyleSettings extends ConsumerWidget {
  const DesktopStyleSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final mode = DesktopAmbientMode.fromName(ref.watch(finampSettingsProvider.desktopAmbientMode));
    String label(DesktopAmbientMode m) => switch (m) {
      DesktopAmbientMode.off => l10n.desktopStyleAmbientOff,
      DesktopAmbientMode.colors => l10n.desktopStyleAmbientColors,
      DesktopAmbientMode.cover => l10n.desktopStyleAmbientCover,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(l10n.desktopStyleSectionTitle, style: Theme.of(context).textTheme.titleSmall),
        ),
        ListTile(
          title: Text(l10n.desktopStyleAmbientTitle),
          subtitle: Text(l10n.desktopStyleAmbientSubtitle),
          trailing: DropdownButton<DesktopAmbientMode>(
            value: mode,
            items: [for (final m in DesktopAmbientMode.values) DropdownMenuItem(value: m, child: Text(label(m)))],
            onChanged: (m) {
              if (m != null) FinampSetters.setDesktopAmbientMode(m.name);
            },
          ),
        ),
        SwitchListTile.adaptive(
          title: Text(l10n.desktopStyleBigCoverTitle),
          subtitle: Text(l10n.desktopStyleBigCoverSubtitle),
          value: ref.watch(finampSettingsProvider.desktopBigCoverArt),
          onChanged: FinampSetters.setDesktopBigCoverArt,
        ),
        SwitchListTile.adaptive(
          title: Text(l10n.desktopStyleReduceEffectsTitle),
          subtitle: Text(l10n.desktopStyleReduceEffectsSubtitle),
          value: ref.watch(finampSettingsProvider.desktopReduceEffects),
          onChanged: FinampSetters.setDesktopReduceEffects,
        ),
      ],
    );
  }
}

/// The ambient background on phones and tablets: the same choice as on desktop (off, album colours, blurred cover).
class MobileStyleSettings extends ConsumerWidget {
  const MobileStyleSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final mode = DesktopAmbientMode.fromName(ref.watch(finampSettingsProvider.desktopAmbientMode));
    String label(DesktopAmbientMode m) => switch (m) {
      DesktopAmbientMode.off => l10n.desktopStyleAmbientOff,
      DesktopAmbientMode.colors => l10n.desktopStyleAmbientColors,
      DesktopAmbientMode.cover => l10n.desktopStyleAmbientCover,
    };
    return ListTile(
      title: Text(l10n.desktopStyleAmbientTitle),
      subtitle: Text(l10n.desktopStyleAmbientSubtitle),
      trailing: DropdownButton<DesktopAmbientMode>(
        value: mode,
        items: [for (final m in DesktopAmbientMode.values) DropdownMenuItem(value: m, child: Text(label(m)))],
        onChanged: (m) {
          if (m != null) FinampSetters.setDesktopAmbientMode(m.name);
        },
      ),
    );
  }
}

import 'package:diapason/screens/visualizer_settings_screen.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Small player-screen button that toggles the spectrum visualizer on tap and
/// opens the visualizer settings on long press.
class SpectrumToggleButton extends ConsumerWidget {
  const SpectrumToggleButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(finampSettingsProvider.visualizerEnabled);
    final color = enabled ? Theme.of(context).colorScheme.primary : null;

    return Tooltip(
      message: enabled ? "Disable spectrum (long press for settings)" : "Enable spectrum (long press for settings)",
      child: InkResponse(
        radius: 24,
        onTap: () => FinampSetters.setVisualizerEnabled(!enabled),
        onLongPress: () {
          HapticFeedback.mediumImpact();
          Navigator.of(context, rootNavigator: true).pushNamed(VisualizerSettingsScreen.routeName);
        },
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Icon(enabled ? TablerIcons.wave_sine : TablerIcons.chart_line, color: color),
        ),
      ),
    );
  }
}

import 'package:diapason/components/visuals/milkdrop_view.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sliders that fine-tune one animated-visual [preset]; each preset keeps its own values.
class MilkdropTuningSliders extends ConsumerWidget {
  const MilkdropTuningSliders({super.key, required this.preset, this.dense = false});

  final MilkdropPreset preset;
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final raw = ref.watch(finampSettingsProvider.milkdropTuning);
    final tune = MilkdropTune.of(raw, preset);

    void save(MilkdropTune value) => FinampSetters.setMilkdropTuning(
      MilkdropTune.update(FinampSettingsHelper.finampSettings.milkdropTuning, preset, value),
    );

    Widget row(String label, double value, double min, double max, MilkdropTune Function(double) apply) => Row(
      children: [
        SizedBox(width: dense ? 84 : 110, child: Text(label)),
        Expanded(
          child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: (v) => save(apply(v))),
        ),
        SizedBox(width: 40, child: Text(value.toStringAsFixed(2), textAlign: TextAlign.end)),
      ],
    );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: dense ? 0 : 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          row("Speed", tune.speed, 0.1, 3, (v) => tune.copyWith(speed: v)),
          row("Intensity", tune.intensity, 0.2, 2.5, (v) => tune.copyWith(intensity: v)),
          row("Trails", tune.trail, 0.5, 0.98, (v) => tune.copyWith(trail: v)),
          row("Warp", tune.warp, 0, 3, (v) => tune.copyWith(warp: v)),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => save(MilkdropTune.defaults),
              child: Text(AppLocalizations.of(context)!.resetToDefaults),
            ),
          ),
        ],
      ),
    );
  }
}

/// A dialog with the tuning sliders of [preset].
Future<void> showMilkdropTuningDialog(BuildContext context, MilkdropPreset preset) {
  final l10n = AppLocalizations.of(context)!;
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(preset.label(l10n)),
      content: SizedBox(width: 420, child: MilkdropTuningSliders(preset: preset, dense: true)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    ),
  );
}

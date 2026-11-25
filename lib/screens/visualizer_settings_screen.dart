import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/utils/platform.dart';

import 'package:audio_service/audio_service.dart';
import 'package:diapason/components/PlayerScreen/spectrum_visualizer.dart';
import 'package:diapason/components/finamp_app_bar_back_button.dart';
import 'package:diapason/components/PlayerScreen/visualizer_style_tune.dart';
import 'package:diapason/components/visuals/milkdrop_tuning_sliders.dart';
import 'package:diapason/components/visuals/milkdrop_view.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/services/waveform_service.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/spectrum_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:permission_handler/permission_handler.dart';

class VisualizerSettingsScreen extends ConsumerWidget {
  const VisualizerSettingsScreen({super.key});

  static const routeName = "/settings/visualizer";

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supported = spectrumSourceAvailable;
    final enabled = supported && ref.watch(finampSettingsProvider.visualizerEnabled);

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.visualizerTitle),
        leading: FinampAppBarBackButton(),
        actions: [
          FinampSettingsHelper.makeSettingsResetButtonWithDialog(context, FinampSettingsHelper.resetVisualizerSettings),
        ],
      ),
      body: Column(
        children: [
          if (supported) _VisualizerPreview(enabled: enabled),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 200.0),
              children: [
                if (!supported)
                  ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text(AppLocalizations.of(context)!.visualizerUnavailable),
                    subtitle: Text(AppLocalizations.of(context)!.visualizerUnavailableBody),
                  ),
                SwitchListTile.adaptive(
                  title: Text(AppLocalizations.of(context)!.visualizerShow),
                  subtitle: Text(AppLocalizations.of(context)!.visualizerShowSubtitle),
                  value: enabled,
                  onChanged: supported ? (value) => _setEnabled(context, value) : null,
                ),
                if (Platform.isAndroid)
                  Padding(
                    padding: EdgeInsets.fromLTRB(16.0, 4.0, 16.0, 12.0),
                    child: Text(AppLocalizations.of(context)!.visualizerAndroidNote, style: TextStyle(fontSize: 12.0)),
                  ),
                _StylePicker(enabled: enabled),
                _StyleEditor(enabled: enabled),
                const Divider(),
                ExpansionTile(
                  title: Text(AppLocalizations.of(context)!.visualizerFrequencies),
                  subtitle: const Text("Bands, frame rate and frequency range, for every style"),
                  children: [
                    _VisualizerSlider(
                      title: AppLocalizations.of(context)!.visualizerBands,
                      subtitle: AppLocalizations.of(context)!.visualizerBandsSubtitle,
                      enabled: enabled,
                      value: ref.watch(finampSettingsProvider.visualizerBins).toDouble(),
                      min: 16,
                      max: 192,
                      divisions: 11,
                      format: (value) => value.round().toString(),
                      onChanged: (value) => FinampSetters.setVisualizerBins(value.round()),
                    ),
                    _VisualizerSlider(
                      title: AppLocalizations.of(context)!.visualizerFrameRate,
                      subtitle: AppLocalizations.of(context)!.visualizerFrameRateSubtitle,
                      enabled: enabled,
                      value: ref.watch(finampSettingsProvider.visualizerFps).toDouble(),
                      min: 10,
                      max: 60,
                      divisions: 10,
                      format: (value) => AppLocalizations.of(context)!.visualizerFps(value.round()),
                      onChanged: (value) => FinampSetters.setVisualizerFps(value.round()),
                    ),
                    SwitchListTile.adaptive(
                      title: Text(AppLocalizations.of(context)!.visualizerLogSpacing),
                      subtitle: Text(AppLocalizations.of(context)!.visualizerLogSpacingSubtitle),
                      value: ref.watch(finampSettingsProvider.visualizerLogScale),
                      onChanged: enabled ? FinampSetters.setVisualizerLogScale : null,
                    ),
                    _VisualizerSlider(
                      title: AppLocalizations.of(context)!.visualizerLowFreq,
                      enabled: enabled,
                      value: ref.watch(finampSettingsProvider.visualizerMinHz),
                      min: 20,
                      max: 500,
                      divisions: 24,
                      format: (value) => "${value.round()} Hz",
                      onChanged: FinampSetters.setVisualizerMinHz,
                    ),
                    _VisualizerSlider(
                      title: AppLocalizations.of(context)!.visualizerHighFreq,
                      enabled: enabled,
                      value: ref.watch(finampSettingsProvider.visualizerMaxHz),
                      min: 2000,
                      max: 20000,
                      divisions: 18,
                      format: (value) => "${(value / 1000).toStringAsFixed(1)} kHz",
                      onChanged: FinampSetters.setVisualizerMaxHz,
                    ),
                    _VisualizerSlider(
                      title: AppLocalizations.of(context)!.visualizerQuietCutoff,
                      subtitle: AppLocalizations.of(context)!.visualizerQuietCutoffSubtitle,
                      enabled: enabled,
                      value: ref.watch(finampSettingsProvider.visualizerDbFloor),
                      min: -120,
                      max: -40,
                      divisions: 16,
                      format: (value) => "${value.round()} dB",
                      onChanged: FinampSetters.setVisualizerDbFloor,
                    ),
                    _VisualizerSlider(
                      title: AppLocalizations.of(context)!.visualizerLoudCutoff,
                      subtitle: AppLocalizations.of(context)!.visualizerLoudCutoffSubtitle,
                      enabled: enabled,
                      value: ref.watch(finampSettingsProvider.visualizerDbCeiling),
                      min: -40,
                      max: 0,
                      divisions: 8,
                      format: (value) => "${value.round()} dB",
                      onChanged: FinampSetters.setVisualizerDbCeiling,
                    ),
                  ],
                ),
                const Divider(),
                if (WaveformService.supported)
                  SwitchListTile.adaptive(
                    title: Text(AppLocalizations.of(context)!.visualWaveformSeekBar),
                    subtitle: Text(AppLocalizations.of(context)!.visualWaveformSeekBarSubtitle),
                    value: ref.watch(finampSettingsProvider.waveformSeekBar),
                    onChanged: FinampSetters.setWaveformSeekBar,
                  ),
                if (MilkdropShader.platformSupported) ...[const Divider(), const _AnimatedVisualSection()],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Android gates the Visualizer effect behind RECORD_AUDIO, so there is no
  /// point enabling the setting if the user says no. iOS taps the player
  /// directly and needs no permission.
  Future<void> _setEnabled(BuildContext context, bool value) async {
    if (!value || !Platform.isAndroid) {
      FinampSetters.setVisualizerEnabled(value);
      return;
    }

    final status = await Permission.microphone.request();
    if (!context.mounted) return;

    if (!status.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.visualizerMicDenied),
          action: status.isPermanentlyDenied
              ? SnackBarAction(label: AppLocalizations.of(context)!.settings, onPressed: openAppSettings)
              : null,
        ),
      );
      return;
    }

    FinampSetters.setVisualizerEnabled(true);
  }
}

/// The real visualizer, fed by whatever is playing, kept in view above the settings so every change shows at once.
class _VisualizerPreview extends StatelessWidget {
  const _VisualizerPreview({required this.enabled});

  final bool enabled;

  static const _height = 168.0;

  @override
  Widget build(BuildContext context) {
    final handler = GetIt.instance<MusicPlayerBackgroundTask>();
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 8.0),
      child: Material(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16.0),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: _height,
          child: StreamBuilder<MediaItem?>(
            stream: handler.mediaItem,
            initialData: handler.mediaItem.valueOrNull,
            builder: (context, snapshot) {
              final item = snapshot.data;
              return Stack(
                children: [
                  if (enabled) const Positioned.fill(child: SpectrumVisualizer(placement: SpectrumPlacement.preview)),
                  if (item != null)
                    Positioned(
                      left: 16.0,
                      right: 4.0,
                      top: 4.0,
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                if (item.artist != null)
                                  Text(
                                    item.artist!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                              ],
                            ),
                          ),
                          StreamBuilder<PlaybackState>(
                            stream: handler.playbackState,
                            initialData: handler.playbackState.valueOrNull,
                            builder: (context, state) {
                              final playing = state.data?.playing ?? false;
                              return IconButton(
                                tooltip: playing
                                    ? AppLocalizations.of(context)!.visualizerPause
                                    : AppLocalizations.of(context)!.visualizerPlay,
                                icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                                onPressed: handler.togglePlayback,
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  if (item == null || !enabled)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Text(
                          !enabled
                              ? AppLocalizations.of(context)!.visualizerPreviewOff
                              : AppLocalizations.of(context)!.visualizerPreviewIdle,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

String _asPercent(double value) => "${(value * 100).round()}%";

class _VisualizerSlider extends StatelessWidget {
  const _VisualizerSlider({
    required this.title,
    required this.enabled,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool enabled;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) format;
  final void Function(double) onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      enabled: enabled,
      title: Text(title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitle != null) Text(subtitle!),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: format(value),
            onChanged: enabled ? onChanged : null,
          ),
        ],
      ),
    );
  }
}

extension VisualizerStyleLabel on VisualizerStyle {
  String label(AppLocalizations l10n) => switch (this) {
    VisualizerStyle.curve => l10n.visualStyleCurve,
    VisualizerStyle.bars => l10n.visualStyleBars,
    VisualizerStyle.mirroredBars => l10n.visualStyleMirroredBars,
    VisualizerStyle.radial => l10n.visualStyleRadial,
    VisualizerStyle.wave => l10n.visualStyleWave,
    VisualizerStyle.particles => l10n.visualStyleParticles,
    VisualizerStyle.blob => l10n.visualStyleBlob,
  };
}

/// Which style is drawn: one tap on a chip, and the editor below customises exactly that style.
class _StylePicker extends ConsumerWidget {
  const _StylePicker({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final current = ref.watch(finampSettingsProvider.visualizerStyle);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final style in VisualizerStyle.values)
            ChoiceChip(
              label: Text(style.label(l10n)),
              selected: style == current,
              onSelected: enabled ? (_) => FinampSetters.setVisualizerStyle(style) : null,
            ),
        ],
      ),
    );
  }
}

/// Everything that shapes the selected style, in four short groups. Values are kept per style (untouched ones follow
/// the global defaults), so each style can have its own look.
class _StyleEditor extends ConsumerWidget {
  const _StyleEditor({required this.enabled});

  final bool enabled;

  static const _swatches = [
    Color(0xFFFF5252),
    Color(0xFFFF9800),
    Color(0xFFFFD740),
    Color(0xFF69F0AE),
    Color(0xFF18FFFF),
    Color(0xFF448AFF),
    Color(0xFFB388FF),
    Color(0xFFFF80AB),
    Color(0xFFFFFFFF),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final g = ref.watch(finampSettingsProvider).value;
    if (g == null) return const SizedBox.shrink();
    final style = g.visualizerStyle;
    final raw = ref.watch(finampSettingsProvider.visualizerStyleTuning);
    final tune = VisualizerStyleTune.of(raw, style);

    void save(VisualizerStyleTune value) => FinampSetters.setVisualizerStyleTuning(
      VisualizerStyleTune.update(FinampSettingsHelper.finampSettings.visualizerStyleTuning, style, value),
    );

    Widget slider(String title, String key, double value, double min, double max, {String Function(double)? format}) {
      return _VisualizerSlider(
        title: title,
        enabled: enabled,
        value: value,
        min: min,
        max: max,
        divisions: 20,
        format: format ?? (v) => v.toStringAsFixed(2),
        onChanged: (v) => save(tune.set(key, v)),
      );
    }

    Widget group(String title, List<Widget> children) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        ...children,
      ],
    );

    final bars = style == VisualizerStyle.bars || style == VisualizerStyle.mirroredBars;
    final filled = style == VisualizerStyle.curve || bars;
    final fill = tune.fillEnabled ?? g.visualizerFillEnabled;
    final heightApplies = style != VisualizerStyle.radial;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        group("Colour", [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SegmentedButton<VisualizerColorMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: VisualizerColorMode.theme, label: Text("Theme")),
                ButtonSegment(value: VisualizerColorMode.custom, label: Text("Custom")),
                ButtonSegment(value: VisualizerColorMode.rainbow, label: Text("Rainbow")),
              ],
              selected: {tune.colorMode},
              onSelectionChanged: enabled ? (v) => save(tune.set("colorMode", v.first.index)) : null,
            ),
          ),
          if (tune.colorMode == VisualizerColorMode.custom)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final color in _swatches)
                    GestureDetector(
                      onTap: enabled ? () => save(tune.set("color", color.toARGB32())) : null,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            width: tune.customColor?.toARGB32() == color.toARGB32() ? 3 : 1,
                            color: tune.customColor?.toARGB32() == color.toARGB32()
                                ? Theme.of(context).colorScheme.primary
                                : Colors.white24,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ]),
        group("Reactivity", [
          slider(
            "Attack",
            "attack",
            tune.attack ?? (1 - (tune.smoothing ?? g.visualizerSmoothing)),
            0.05,
            1,
            format: _asPercent,
          ),
          slider(
            "Release",
            "release",
            tune.release ?? ((tune.smoothing ?? g.visualizerSmoothing) * 0.25),
            0.02,
            1,
            format: _asPercent,
          ),
          slider(
            "Treble boost",
            "tilt",
            tune.tilt,
            -1,
            1,
            format: (v) => v == 0 ? "flat" : (v > 0 ? "+${v.toStringAsFixed(1)}" : v.toStringAsFixed(1)),
          ),
          slider("Contrast", "contrast", tune.contrast, 0.5, 2.5, format: (v) => v.toStringAsFixed(2)),
          SwitchListTile.adaptive(
            title: const Text("Auto gain"),
            subtitle: const Text("Quiet tracks move as much as loud ones"),
            value: tune.autoGain,
            onChanged: enabled ? (v) => save(tune.set("autoGain", v)) : null,
          ),
        ]),
        group("Size and motion", [
          if (heightApplies)
            slider(
              l10n.visualizerHeight,
              "heightFactor",
              tune.heightFactor ?? g.visualizerHeightFactor,
              0.1,
              1,
              format: _asPercent,
            ),
          slider(
            l10n.visualizerScale,
            "scale",
            tune.scale ?? g.visualizerScale,
            0.25,
            2,
            format: (v) => "${v.toStringAsFixed(2)}x",
          ),
          slider(
            l10n.visualizerSmoothing,
            "smoothing",
            tune.smoothing ?? g.visualizerSmoothing,
            0,
            0.95,
            format: _asPercent,
          ),
        ]),
        group("Shape", [
          if (style == VisualizerStyle.curve)
            SwitchListTile.adaptive(
              title: Text(l10n.visualizerSmoothCurve),
              value: tune.useSplines ?? g.visualizerUseSplines,
              onChanged: enabled ? (v) => save(tune.set("useSplines", v)) : null,
            ),
          if (bars) ...[
            slider("Bar width", "barWidth", tune.barWidth, 0.2, 1, format: _asPercent),
            slider("Roundness", "cornerRadius", tune.cornerRadius, 0, 1, format: _asPercent),
          ],
          if (style == VisualizerStyle.radial) ...[
            slider("Ring size", "innerRadius", tune.innerRadius ?? 0.45, 0.2, 0.8, format: _asPercent),
            slider(
              "Spin",
              "rotation",
              tune.rotation,
              0,
              1.5,
              format: (v) => v == 0 ? "off" : "${v.toStringAsFixed(1)}x",
            ),
          ],
          if (style == VisualizerStyle.particles)
            slider(
              "Particle size",
              "particleSize",
              tune.particleSize,
              0.4,
              3,
              format: (v) => "${v.toStringAsFixed(1)}x",
            ),
          if (filled || style == VisualizerStyle.wave)
            slider(
              l10n.visualizerOutline,
              "strokeWidth",
              tune.strokeWidth ?? g.visualizerStrokeWidth,
              0,
              5,
              format: (v) => v.toStringAsFixed(1),
            ),
          if (filled)
            SwitchListTile.adaptive(
              title: Text(l10n.visualizerFill),
              value: fill,
              onChanged: enabled ? (v) => save(tune.set("fillEnabled", v)) : null,
            ),
          if (filled && fill) ...[
            slider(
              l10n.visualizerFillBottom,
              "bottomOpacity",
              tune.bottomOpacity ?? g.visualizerBottomOpacity,
              0,
              1,
              format: _asPercent,
            ),
            slider(
              l10n.visualizerFillTop,
              "topOpacity",
              tune.topOpacity ?? g.visualizerTopOpacity,
              0,
              1,
              format: _asPercent,
            ),
          ],
          if (style != VisualizerStyle.particles && style != VisualizerStyle.blob)
            slider("Glow", "glow", tune.glow, 0, 1, format: (v) => v == 0 ? "off" : _asPercent(v)),
        ]),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextButton(
              onPressed: tune.isEmpty ? null : () => save(VisualizerStyleTune.none),
              child: Text(l10n.resetToDefaults),
            ),
          ),
        ),
      ],
    );
  }
}

/// The animated visual: pick a preset (or let them cycle), and its own sliders appear below.
class _AnimatedVisualSection extends ConsumerStatefulWidget {
  const _AnimatedVisualSection();

  @override
  ConsumerState<_AnimatedVisualSection> createState() => _AnimatedVisualSectionState();
}

class _AnimatedVisualSectionState extends ConsumerState<_AnimatedVisualSection> {
  int _editing = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final setting = ref.watch(finampSettingsProvider.milkdropPreset);
    final shown = setting >= 0 ? setting % MilkdropPreset.values.length : _editing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 12.0, 16.0, 0.0),
          child: Text(l10n.visualAnimatedTitle, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        SwitchListTile.adaptive(
          title: Text(l10n.visualAnimatedOnCover),
          subtitle: Text(l10n.visualAnimatedOnCoverSubtitle),
          value: ref.watch(finampSettingsProvider.milkdropOnCover),
          onChanged: FinampSetters.setMilkdropOnCover,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ChoiceChip(
                label: Text(l10n.visualAnimatedPresetCycle),
                selected: setting < 0,
                onSelected: (_) => FinampSetters.setMilkdropPreset(-1),
              ),
              for (final option in MilkdropPreset.values)
                ChoiceChip(
                  label: Text(option.label(l10n)),
                  selected: setting >= 0 && shown == option.index,
                  onSelected: (_) {
                    setState(() => _editing = option.index);
                    FinampSetters.setMilkdropPreset(option.index);
                  },
                ),
            ],
          ),
        ),
        // Tuning follows the chosen preset; while cycling, pick which one to edit with the chips above.
        MilkdropTuningSliders(preset: MilkdropPreset.values[shown]),
        SwitchListTile.adaptive(
          title: Text(l10n.visualAnimatedLowPower),
          subtitle: Text(l10n.visualAnimatedLowPowerSubtitle),
          value: ref.watch(finampSettingsProvider.milkdropLowPower),
          onChanged: FinampSetters.setMilkdropLowPower,
        ),
      ],
    );
  }
}

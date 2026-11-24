import 'package:diapason/l10n/app_localizations.dart';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:diapason/components/PlayerScreen/spectrum_visualizer.dart';
import 'package:diapason/components/finamp_app_bar_back_button.dart';
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
                const Divider(),
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
                _VisualizerSlider(
                  title: AppLocalizations.of(context)!.visualizerHeight,
                  subtitle: AppLocalizations.of(context)!.visualizerHeightSubtitle,
                  enabled: enabled,
                  value: ref.watch(finampSettingsProvider.visualizerHeightFactor),
                  min: 0.1,
                  max: 1.0,
                  divisions: 18,
                  format: _asPercent,
                  onChanged: FinampSetters.setVisualizerHeightFactor,
                ),
                _VisualizerSlider(
                  title: AppLocalizations.of(context)!.visualizerSmoothing,
                  subtitle: AppLocalizations.of(context)!.visualizerSmoothingSubtitle,
                  enabled: enabled,
                  value: ref.watch(finampSettingsProvider.visualizerSmoothing),
                  min: 0.0,
                  max: 0.95,
                  divisions: 19,
                  format: _asPercent,
                  onChanged: FinampSetters.setVisualizerSmoothing,
                ),
                _VisualizerSlider(
                  title: AppLocalizations.of(context)!.visualizerScale,
                  subtitle: AppLocalizations.of(context)!.visualizerScaleSubtitle,
                  enabled: enabled,
                  value: ref.watch(finampSettingsProvider.visualizerScale),
                  min: 0.25,
                  max: 2.0,
                  divisions: 7,
                  format: (value) => "${value.toStringAsFixed(2)}x",
                  onChanged: FinampSetters.setVisualizerScale,
                ),
                const Divider(),
                Padding(
                  padding: EdgeInsets.fromLTRB(16.0, 12.0, 16.0, 0.0),
                  child: Text(
                    AppLocalizations.of(context)!.visualizerFrequencies,
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
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
                const Divider(),
                Padding(
                  padding: EdgeInsets.fromLTRB(16.0, 12.0, 16.0, 0.0),
                  child: Text(
                    AppLocalizations.of(context)!.visualizerAppearance,
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                SwitchListTile.adaptive(
                  title: Text(AppLocalizations.of(context)!.visualizerSmoothCurve),
                  subtitle: Text(AppLocalizations.of(context)!.visualizerSmoothCurveSubtitle),
                  value: ref.watch(finampSettingsProvider.visualizerUseSplines),
                  onChanged: enabled ? FinampSetters.setVisualizerUseSplines : null,
                ),
                SwitchListTile.adaptive(
                  title: Text(AppLocalizations.of(context)!.visualizerFill),
                  value: ref.watch(finampSettingsProvider.visualizerFillEnabled),
                  onChanged: enabled ? FinampSetters.setVisualizerFillEnabled : null,
                ),
                _VisualizerSlider(
                  title: AppLocalizations.of(context)!.visualizerFillBottom,
                  enabled: enabled,
                  value: ref.watch(finampSettingsProvider.visualizerBottomOpacity),
                  min: 0.0,
                  max: 1.0,
                  divisions: 20,
                  format: _asPercent,
                  onChanged: FinampSetters.setVisualizerBottomOpacity,
                ),
                _VisualizerSlider(
                  title: AppLocalizations.of(context)!.visualizerFillTop,
                  enabled: enabled,
                  value: ref.watch(finampSettingsProvider.visualizerTopOpacity),
                  min: 0.0,
                  max: 1.0,
                  divisions: 20,
                  format: _asPercent,
                  onChanged: FinampSetters.setVisualizerTopOpacity,
                ),
                _VisualizerSlider(
                  title: AppLocalizations.of(context)!.visualizerOutline,
                  subtitle: AppLocalizations.of(context)!.visualizerOutlineSubtitle,
                  enabled: enabled,
                  value: ref.watch(finampSettingsProvider.visualizerStrokeWidth),
                  min: 0.0,
                  max: 5.0,
                  divisions: 10,
                  format: (value) => value.toStringAsFixed(1),
                  onChanged: FinampSetters.setVisualizerStrokeWidth,
                ),
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
                  if (enabled) const Positioned.fill(child: SpectrumVisualizer()),
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

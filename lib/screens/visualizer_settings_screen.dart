import 'dart:io';

import 'package:diapason/components/finamp_app_bar_back_button.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/spectrum_source.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
        title: const Text("Visualizer"),
        leading: FinampAppBarBackButton(),
        actions: [
          FinampSettingsHelper.makeSettingsResetButtonWithDialog(context, FinampSettingsHelper.resetVisualizerSettings),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 200.0),
        children: [
          if (!supported)
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text("Not available on this platform"),
              subtitle: Text(
                "The visualizer needs access to the audio being played, which only phones and tablets expose.",
              ),
            ),
          SwitchListTile.adaptive(
            title: const Text("Show visualizer"),
            subtitle: const Text("Draws a live spectrum curve behind the player screen controls"),
            value: enabled,
            onChanged: supported ? (value) => _setEnabled(context, value) : null,
          ),
          if (Platform.isAndroid)
            const Padding(
              padding: EdgeInsets.fromLTRB(16.0, 4.0, 16.0, 12.0),
              child: Text(
                "Android only lets an app read its own audio through the microphone permission, so turning this on "
                "asks for it. Nothing is recorded and nothing leaves the device — the permission is only used to read "
                "the levels of the track you are playing.",
                style: TextStyle(fontSize: 12.0),
              ),
            ),
          const Divider(),
          _VisualizerSlider(
            title: "Bands",
            subtitle: "How many points the curve is built from",
            enabled: enabled,
            value: ref.watch(finampSettingsProvider.visualizerBins).toDouble(),
            min: 16,
            max: 192,
            divisions: 11,
            format: (value) => value.round().toString(),
            onChanged: (value) => FinampSetters.setVisualizerBins(value.round()),
          ),
          _VisualizerSlider(
            title: "Frame rate",
            subtitle: "Most devices cap the audio capture at 20 fps regardless of what is asked for",
            enabled: enabled,
            value: ref.watch(finampSettingsProvider.visualizerFps).toDouble(),
            min: 10,
            max: 60,
            divisions: 10,
            format: (value) => "${value.round()} fps",
            onChanged: (value) => FinampSetters.setVisualizerFps(value.round()),
          ),
          _VisualizerSlider(
            title: "Height",
            subtitle: "Share of the screen the curve rises into",
            enabled: enabled,
            value: ref.watch(finampSettingsProvider.visualizerHeightFactor),
            min: 0.1,
            max: 1.0,
            divisions: 18,
            format: _asPercent,
            onChanged: FinampSetters.setVisualizerHeightFactor,
          ),
          _VisualizerSlider(
            title: "Smoothing",
            subtitle: "Higher values make the curve settle more slowly",
            enabled: enabled,
            value: ref.watch(finampSettingsProvider.visualizerSmoothing),
            min: 0.0,
            max: 0.95,
            divisions: 19,
            format: _asPercent,
            onChanged: FinampSetters.setVisualizerSmoothing,
          ),
          _VisualizerSlider(
            title: "Scale",
            subtitle: "Multiplier applied to the curve's height",
            enabled: enabled,
            value: ref.watch(finampSettingsProvider.visualizerScale),
            min: 0.25,
            max: 2.0,
            divisions: 7,
            format: (value) => "${value.toStringAsFixed(2)}x",
            onChanged: FinampSetters.setVisualizerScale,
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16.0, 12.0, 16.0, 0.0),
            child: Text("Frequencies", style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          SwitchListTile.adaptive(
            title: const Text("Logarithmic spacing"),
            subtitle: const Text("Gives bass and treble equal room. Linear spacing crowds everything to the left"),
            value: ref.watch(finampSettingsProvider.visualizerLogScale),
            onChanged: enabled ? FinampSetters.setVisualizerLogScale : null,
          ),
          _VisualizerSlider(
            title: "Lowest frequency",
            enabled: enabled,
            value: ref.watch(finampSettingsProvider.visualizerMinHz),
            min: 20,
            max: 500,
            divisions: 24,
            format: (value) => "${value.round()} Hz",
            onChanged: FinampSetters.setVisualizerMinHz,
          ),
          _VisualizerSlider(
            title: "Highest frequency",
            enabled: enabled,
            value: ref.watch(finampSettingsProvider.visualizerMaxHz),
            min: 2000,
            max: 20000,
            divisions: 18,
            format: (value) => "${(value / 1000).toStringAsFixed(1)} kHz",
            onChanged: FinampSetters.setVisualizerMaxHz,
          ),
          _VisualizerSlider(
            title: "Quiet cutoff",
            subtitle: "Levels below this map to a flat curve. Raise it if the curve never rests",
            enabled: enabled,
            value: ref.watch(finampSettingsProvider.visualizerDbFloor),
            min: -120,
            max: -40,
            divisions: 16,
            format: (value) => "${value.round()} dB",
            onChanged: FinampSetters.setVisualizerDbFloor,
          ),
          _VisualizerSlider(
            title: "Loud cutoff",
            subtitle: "Levels above this max out the curve. Lower it if quiet tracks barely move",
            enabled: enabled,
            value: ref.watch(finampSettingsProvider.visualizerDbCeiling),
            min: -40,
            max: 0,
            divisions: 8,
            format: (value) => "${value.round()} dB",
            onChanged: FinampSetters.setVisualizerDbCeiling,
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16.0, 12.0, 16.0, 0.0),
            child: Text("Appearance", style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          SwitchListTile.adaptive(
            title: const Text("Smooth curve"),
            subtitle: const Text("Interpolate between bands instead of drawing straight segments"),
            value: ref.watch(finampSettingsProvider.visualizerUseSplines),
            onChanged: enabled ? FinampSetters.setVisualizerUseSplines : null,
          ),
          SwitchListTile.adaptive(
            title: const Text("Fill under the curve"),
            value: ref.watch(finampSettingsProvider.visualizerFillEnabled),
            onChanged: enabled ? FinampSetters.setVisualizerFillEnabled : null,
          ),
          _VisualizerSlider(
            title: "Fill opacity at the bottom",
            enabled: enabled,
            value: ref.watch(finampSettingsProvider.visualizerBottomOpacity),
            min: 0.0,
            max: 1.0,
            divisions: 20,
            format: _asPercent,
            onChanged: FinampSetters.setVisualizerBottomOpacity,
          ),
          _VisualizerSlider(
            title: "Fill opacity at the top",
            enabled: enabled,
            value: ref.watch(finampSettingsProvider.visualizerTopOpacity),
            min: 0.0,
            max: 1.0,
            divisions: 20,
            format: _asPercent,
            onChanged: FinampSetters.setVisualizerTopOpacity,
          ),
          _VisualizerSlider(
            title: "Outline width",
            subtitle: "Set to zero to hide the outline",
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
          content: const Text("The visualizer cannot read the audio without the microphone permission."),
          action: status.isPermanentlyDenied ? SnackBarAction(label: "Settings", onPressed: openAppSettings) : null,
        ),
      );
      return;
    }

    FinampSetters.setVisualizerEnabled(true);
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

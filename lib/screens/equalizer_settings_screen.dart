import 'dart:async';

import 'package:diapason/components/finamp_app_bar_back_button.dart';
import 'package:diapason/models/equalizer_presets.dart';
import 'package:diapason/services/feedback_helper.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';

class EqualizerSettingsScreen extends ConsumerStatefulWidget {
  const EqualizerSettingsScreen({super.key});

  static const routeName = "/settings/equalizer";

  @override
  ConsumerState<EqualizerSettingsScreen> createState() => _EqualizerSettingsScreenState();
}

class _EqualizerSettingsScreenState extends ConsumerState<EqualizerSettingsScreen> {
  final _audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
  late final Future<List<double>> _bandFrequencies = _audioHandler.getEqualizerBandFrequencies();

  @override
  Widget build(BuildContext context) {
    final available = _audioHandler.equalizerAvailable;
    final enabled = available && ref.watch(finampSettingsProvider.equalizerEnabled);
    final activePreset = ref.watch(finampSettingsProvider.equalizerActivePreset);

    return Scaffold(
      appBar: AppBar(
        title: const Text("Equalizer"),
        leading: FinampAppBarBackButton(),
        actions: [
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: "Reset to flat",
            onPressed: available
                ? () {
                    unawaited(_audioHandler.applyEqualizerPreset("Flat"));
                    unawaited(_audioHandler.setEqualizerEnabled(false));
                  }
                : null,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 200.0),
        children: [
          if (!available)
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text("Not available on this device"),
              subtitle: Text("This device doesn't provide the platform audio effect the equalizer needs."),
            ),
          SwitchListTile.adaptive(
            title: const Text("Enable equalizer"),
            value: enabled,
            onChanged: available ? _audioHandler.setEqualizerEnabled : null,
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16.0, 4.0, 16.0, 8.0),
            child: Wrap(
              spacing: 8.0,
              runSpacing: 8.0,
              children: [
                for (final name in equalizerPresets.keys)
                  ChoiceChip(
                    label: Text(name),
                    selected: activePreset == name,
                    onSelected: enabled
                        ? (_) {
                            FeedbackHelper.feedback(FeedbackType.selection);
                            unawaited(_audioHandler.applyEqualizerPreset(name));
                          }
                        : null,
                  ),
              ],
            ),
          ),
          const Divider(),
          FutureBuilder<List<double>>(
            future: _bandFrequencies,
            builder: (context, snapshot) {
              final frequencies = snapshot.data ?? const [];
              if (frequencies.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(24.0),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              return Column(
                children: [
                  for (var i = 0; i < frequencies.length; i++)
                    _EqualizerBandSlider(
                      frequency: frequencies[i],
                      enabled: enabled,
                      gain: ref.watch(finampSettingsProvider.equalizerBandGains(i)) ?? 0.0,
                      onChanged: (value) => _audioHandler.setEqualizerBandGain(i, value),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

String _formatFrequency(double hz) {
  if (hz >= 1000) {
    final khz = hz / 1000;
    return khz == khz.roundToDouble() ? "${khz.round()} kHz" : "${khz.toStringAsFixed(1)} kHz";
  }
  return "${hz.round()} Hz";
}

class _EqualizerBandSlider extends StatefulWidget {
  const _EqualizerBandSlider({
    required this.frequency,
    required this.enabled,
    required this.gain,
    required this.onChanged,
  });

  final double frequency;
  final bool enabled;
  final double gain;
  final void Function(double) onChanged;

  @override
  State<_EqualizerBandSlider> createState() => _EqualizerBandSliderState();
}

class _EqualizerBandSliderState extends State<_EqualizerBandSlider> {
  double? _dragValue;
  Timer? _debouncer;

  @override
  void dispose() {
    _debouncer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = (_dragValue ?? widget.gain).clamp(-12.0, 12.0);
    return ListTile(
      enabled: widget.enabled,
      title: Text(_formatFrequency(widget.frequency)),
      subtitle: Slider(
        value: value,
        min: -12.0,
        max: 12.0,
        divisions: 48,
        label: "${value.toStringAsFixed(1)} dB",
        onChanged: widget.enabled
            ? (newValue) {
                setState(() => _dragValue = newValue);
                _debouncer?.cancel();
                _debouncer = Timer(const Duration(milliseconds: 150), () {
                  widget.onChanged(newValue);
                });
              }
            : null,
        onChangeEnd: widget.enabled
            ? (newValue) {
                _debouncer?.cancel();
                widget.onChanged(newValue);
                FeedbackHelper.feedback(FeedbackType.selection);
                setState(() => _dragValue = null);
              }
            : null,
      ),
    );
  }
}

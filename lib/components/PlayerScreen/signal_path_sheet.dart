import 'package:diapason/screens/desktop/desktop_router.dart';
import 'dart:async';

import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/hifi/dsd/dsd_container.dart';
import 'package:diapason/services/hifi/dsd_audio_source.dart';
import 'package:diapason/services/hifi/hifi_platform.dart';
import 'package:diapason/services/hifi/hifi_service.dart';
import 'package:diapason/services/hifi/signal_path.dart';
import 'package:flutter/material.dart';

/// Shows where the current track's samples go, from the file to the DAC, and whether they arrive untouched.
Future<void> showSignalPathSheet(BuildContext context, {required SignalSource source, required double speed}) {
  return showAdaptiveModalSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _SignalPathSheet(source: source, speed: speed),
  );
}

class _SignalPathSheet extends StatefulWidget {
  const _SignalPathSheet({required this.source, required this.speed});

  final SignalSource source;
  final double speed;

  @override
  State<_SignalPathSheet> createState() => _SignalPathSheetState();
}

class _SignalPathSheetState extends State<_SignalPathSheet> {
  SignalPath? _path;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    // The output can change under the track (mpv reopens it, a device is plugged in).
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final hifi = HifiService.instance;
    final settings = FinampSettingsHelper.finampSettings;
    final bitPerfect = hifi.bitPerfectActive;
    final dsd = widget.source.dsd;
    final feedRate = dsd != null ? dsd.outputRate : widget.source.sampleRate;
    final output = await hifi.readOutput(sourceRate: feedRate);
    final processing = bitPerfect
        ? const SignalProcessing()
        : SignalProcessing(
            volume: settings.currentVolume,
            replayGain: settings.volumeNormalizationActive,
            equalizer: settings.equalizerEnabled,
            crossfade: settings.crossfadeSeconds > 0 || settings.automixEnabled,
            speed: widget.speed,
          );
    if (!mounted) return;
    setState(() {
      _path = SignalPath(source: widget.source, processing: processing, output: output, bitPerfectMode: bitPerfect);
    });
  }

  static String _rate(int? hz) {
    if (hz == null) return "?";
    if (hz >= 1000000) return dsdRateName(hz);
    final khz = hz / 1000;
    return "${khz == khz.roundToDouble() ? khz.toStringAsFixed(0) : khz.toStringAsFixed(1)} kHz";
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final path = _path;
    if (path == null) {
      return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
    }
    final theme = Theme.of(context);
    final source = path.source;
    final output = path.output;
    final dsd = source.dsd;

    final sourceLine = [
      (source.codec ?? source.container ?? l10n.hifiUnknown).toUpperCase(),
      if (dsd != null) ...[dsdRateName(dsd.dsdRate), "${dsd.channels} ch", if (dsd.dst) "DST"],
      if (dsd == null && source.sampleRate != null) _rate(source.sampleRate),
      if (dsd == null && source.bitDepth != null) "${source.bitDepth}-bit",
      if (dsd == null && source.channels != null) "${source.channels} ch",
    ].join(" · ");

    final decoding = source.transcoded
        ? l10n.hifiTranscodedByServer
        : switch (dsd?.delivery) {
            null => l10n.hifiDecodedByPlayer,
            DsdDelivery.native => l10n.hifiDeliveryNative,
            DsdDelivery.pcm => "${l10n.hifiDeliveryPcm} · ${_rate(dsd!.outputRate)} · 24-bit",
            DsdDelivery.dop => "${l10n.hifiDeliveryDop} · ${_rate(dsd!.outputRate)}",
            DsdDelivery.dstWrapped => l10n.hifiDeliveryDst,
          };

    final processing = <String>[
      if (path.bitPerfectMode) l10n.hifiVolumeLocked,
      if (path.issues.contains(SignalPathIssue.volume)) l10n.hifiIssueVolume,
      if (path.issues.contains(SignalPathIssue.replayGain)) l10n.hifiIssueReplayGain,
      if (path.issues.contains(SignalPathIssue.equalizer)) l10n.hifiIssueEqualizer,
      if (path.issues.contains(SignalPathIssue.crossfade)) l10n.hifiIssueCrossfade,
      if (path.issues.contains(SignalPathIssue.speed)) l10n.hifiIssueSpeed,
    ];

    final outputLine = [
      if (output.api != null) output.api!,
      if (output.device != null) output.device!,
      if (output.sampleRate != null) _rate(output.sampleRate),
      if (output.format != null) output.format!,
      if (output.bitDepth != null) "${output.bitDepth}-bit",
      if (output.exclusive != null) output.exclusive! ? l10n.hifiExclusive : l10n.hifiShared,
      if (output.resampled != null) output.resampled! ? l10n.hifiResampled : l10n.hifiNotResampled,
    ].join(" · ");

    final (verdictText, verdictIcon, verdictColor) = switch (path.verdict) {
      SignalPathVerdict.bitPerfect => (l10n.hifiVerdictBitPerfect, Icons.verified, Colors.green),
      SignalPathVerdict.transparent => (l10n.hifiVerdictTransparent, Icons.check_circle_outline, Colors.teal),
      SignalPathVerdict.notBitPerfect => (l10n.hifiVerdictNotBitPerfect, Icons.info_outline, theme.colorScheme.outline),
      SignalPathVerdict.unknown => (l10n.hifiVerdictUnknown, Icons.help_outline, theme.colorScheme.outline),
    };

    String issueText(SignalPathIssue issue) => switch (issue) {
      SignalPathIssue.platform => l10n.hifiIssuePlatform,
      SignalPathIssue.modeOff => l10n.hifiIssueModeOff,
      SignalPathIssue.transcoded => l10n.hifiIssueTranscoded,
      SignalPathIssue.dsdConverted => l10n.hifiIssueDsdConverted,
      SignalPathIssue.resampled => l10n.hifiIssueResampled,
      SignalPathIssue.volume => l10n.hifiIssueVolume,
      SignalPathIssue.replayGain => l10n.hifiIssueReplayGain,
      SignalPathIssue.equalizer => l10n.hifiIssueEqualizer,
      SignalPathIssue.crossfade => l10n.hifiIssueCrossfade,
      SignalPathIssue.speed => l10n.hifiIssueSpeed,
      SignalPathIssue.sharedMixer => l10n.hifiIssueSharedMixer,
      SignalPathIssue.playerFilters => l10n.hifiIssueFilters,
      SignalPathIssue.decoderDepth => l10n.hifiIssueDecoderDepth,
      SignalPathIssue.noBitPerfectMixer => l10n.hifiIssueNoBitPerfectMixer,
    };

    Widget stage(IconData icon, String title, String value) => ListTile(
      dense: true,
      leading: Icon(icon),
      title: Text(title, style: theme.textTheme.labelMedium),
      subtitle: Text(value, style: theme.textTheme.bodyMedium),
    );

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(l10n.hifiSignalPathTitle, style: theme.textTheme.titleLarge),
            ),
            ListTile(
              leading: Icon(verdictIcon, color: verdictColor),
              title: Text(verdictText, style: theme.textTheme.titleMedium?.copyWith(color: verdictColor)),
            ),
            stage(Icons.audio_file_outlined, l10n.hifiSource, sourceLine),
            stage(Icons.memory, l10n.hifiDecoding, decoding),
            stage(Icons.tune, l10n.hifiProcessing, processing.isEmpty ? l10n.hifiNone : processing.join("\n")),
            stage(
              output.backend == HifiBackend.none ? Icons.phone_iphone : Icons.speaker,
              l10n.hifiOutput,
              outputLine.isEmpty ? l10n.hifiUnknown : outputLine,
            ),
            if (path.issues.isNotEmpty) const Divider(),
            for (final issue in path.issues)
              ListTile(dense: true, leading: const Icon(Icons.remove, size: 16), title: Text(issueText(issue))),
          ],
        ),
      ),
    );
  }
}

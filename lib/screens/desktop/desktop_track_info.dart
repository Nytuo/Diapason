import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/current_track_metadata_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DesktopTrackInfoLine extends ConsumerWidget {
  const DesktopTrackInfoLine({super.key, this.fontSize = 10, this.center = false});

  final double fontSize;
  final bool center;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = DesktopThemeScope.of(context);
    final metadata = ref.watch(currentTrackMetadataProvider).valueOrNull;
    if (metadata == null) return const SizedBox.shrink();

    final source = metadata.mediaSourceInfo;
    final audio = source.mediaStreams.where((s) => s.type == "Audio").firstOrNull;

    final parts = <String>[
      if ((source.container ?? audio?.codec) != null) (source.container ?? audio!.codec!).toUpperCase(),
      if (audio?.bitDepth != null) "${audio!.bitDepth}bit",
      if (audio?.sampleRate != null) "${(audio!.sampleRate! / 1000).toStringAsFixed(1)}kHz",
      if (audio?.channels != null) "${audio!.channels}ch",
      if ((audio?.bitRate ?? source.bitrate) != null) "${((audio?.bitRate ?? source.bitrate)! / 1000).round()}kbps",
    ];
    if (parts.isEmpty) return const SizedBox.shrink();

    return Text(
      parts.join("  ·  "),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: center ? TextAlign.center : TextAlign.start,
      style: TextStyle(
        color: p.textTertiary,
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

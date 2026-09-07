import 'dart:io';

import 'package:diapason/components/SettingsScreen/finamp_settings_dropdown.dart';
import 'package:diapason/components/TranscodingSettingsScreen/bitrate_selector.dart';
import 'package:diapason/components/TranscodingSettingsScreen/transcode_switch.dart';
import 'package:diapason/components/finamp_app_bar_back_button.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/media_source.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class TranscodingSettingsScreen extends StatefulWidget {
  const TranscodingSettingsScreen({super.key});
  static const routeName = "/settings/transcoding";
  @override
  State<TranscodingSettingsScreen> createState() => _TranscodingSettingsScreenState();
}

class _TranscodingSettingsScreenState extends State<TranscodingSettingsScreen> {
  bool get _hasJellyfinSource => GetIt.instance<BackendRegistry>().ofKind(MediaSourceKind.jellyfin).isNotEmpty;
  bool get _hasSubsonicSource => GetIt.instance<BackendRegistry>().ofKind(MediaSourceKind.subsonic).isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.transcoding),
        leading: FinampAppBarBackButton(),
        actions: [
          FinampSettingsHelper.makeSettingsResetButtonWithDialog(
            context,
            FinampSettingsHelper.resetTranscodingSettings,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 200.0),
        children: [
          const TranscodeSwitch(),
          if (_hasJellyfinSource) const StreamingTranscodingFormatDropdownListTile(),
          if (_hasSubsonicSource) const StreamingTranscodeCodecDropdownListTile(),
          const BitrateSelector(),
          Divider(),
          const DownloadTranscodeEnableDropdownListTile(),
          const DownloadTranscodeCodecDropdownListTile(),
          const DownloadBitrateSelectorWrapper(),
          Divider(),
          const MultichannelHandlingSelector(),
        ],
      ),
    );
  }
}

/// Only shows [DownloadBitrateSelector] when the download codec isn't
/// lossless, since lossless codecs don't have a configurable bitrate.
class DownloadBitrateSelectorWrapper extends ConsumerWidget {
  const DownloadBitrateSelectorWrapper({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final codec = ref.watch(finampSettingsProvider.downloadTranscodingProfile).codec;
    if (codec.isLossless) {
      return const SizedBox.shrink();
    }
    return const DownloadBitrateSelector();
  }
}

class DownloadBitrateSelector extends ConsumerWidget {
  const DownloadBitrateSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transcodeProfile = ref.watch(finampSettingsProvider.downloadTranscodingProfile);
    return Column(
      children: [
        ListTile(
          title: Text(AppLocalizations.of(context)!.downloadBitrate),
          subtitle: Text(AppLocalizations.of(context)!.downloadBitrateSubtitle),
        ),
        // We do all of this division/multiplication because Jellyfin wants us to specify bitrates in bits, not kilobits.
        Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Slider(
              min: 64,
              max: 320,
              value: (transcodeProfile.stereoBitrate / 1000).clamp(64, 320),
              divisions: 8,
              label: transcodeProfile.bitrateKbps,
              onChanged: (value) => FinampSetters.setDownloadTranscodeBitrate((value * 1000).toInt()),
              autofocus: false,
              focusNode: FocusNode(skipTraversal: true, canRequestFocus: false),
            ),
            Text(transcodeProfile.bitrateKbps, style: Theme.of(context).textTheme.titleMedium),
            SizedBox(height: 12),
          ],
        ),
      ],
    );
  }
}

class DownloadTranscodeEnableDropdownListTile extends ConsumerWidget {
  const DownloadTranscodeEnableDropdownListTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      title: Text(AppLocalizations.of(context)!.downloadTranscodeEnableTitle),
      subtitle: FinampSettingsDropdown<TranscodeDownloadsSetting>(
        dropdownItems: TranscodeDownloadsSetting.values
            .map(
              (e) => DropdownMenuEntry<TranscodeDownloadsSetting>(
                value: e,
                label: AppLocalizations.of(context)!.downloadTranscodeEnableOption(e.name),
              ),
            )
            .toList(),
        selectedValue: ref.watch(finampSettingsProvider.shouldTranscodeDownloads),
        onSelected: FinampSetters.setShouldTranscodeDownloads.ifNonNull,
      ),
    );
  }
}

/// Sources with transcoding enabled that don't list [codec] among what they
/// support without extra, non-default server-side configuration. Pass [kind]
/// to only consider sources of that kind (e.g. a codec picker that only
/// affects Subsonic sources shouldn't warn about Jellyfin ones).
Iterable<String> _sourcesMissingDefaultSupport(FinampTranscodingCodec codec, {MediaSourceKind? kind}) =>
    GetIt.instance<BackendRegistry>().enabled
        .where((b) => kind == null || b.config.kind == kind)
        .where((b) => b.capabilities.transcoding && !b.capabilities.defaultTranscodingCodecs.contains(codec))
        .map((b) => b.config.name);

class DownloadTranscodeCodecDropdownListTile extends ConsumerWidget {
  const DownloadTranscodeCodecDropdownListTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final codec = ref.watch(finampSettingsProvider.downloadTranscodingProfile).codec;
    return ListTile(
      title: Text(AppLocalizations.of(context)!.downloadTranscodeCodecTitle),
      subtitle: Column(
        spacing: 4.0,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FinampSettingsDropdown<FinampTranscodingCodec>(
            dropdownItems: FinampTranscodingCodec.values
                .where((element) => !Platform.isIOS || element.iosCompatible)
                .where((element) => element != FinampTranscodingCodec.original)
                .map((e) {
                  final missing = _sourcesMissingDefaultSupport(e).toList();
                  return DropdownMenuEntry<FinampTranscodingCodec>(
                    value: e,
                    label: e.name.toUpperCase(),
                    trailingIcon: missing.isEmpty
                        ? null
                        : Tooltip(
                            message: AppLocalizations.of(
                              context,
                            )!.downloadTranscodeCodecMaybeUnsupported(missing.join(", ")),
                            child: Icon(
                              TablerIcons.alert_triangle,
                              size: 16,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                  );
                })
                .toList(),
            selectedValue: codec,
            onSelected: FinampSetters.setDownloadTranscodingCodec.ifNonNull,
          ),
          if (codec.isLossless)
            Text(
              AppLocalizations.of(context)!.losslessTranscodeDownloadWarning,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          if (_sourcesMissingDefaultSupport(codec).toList() case final missing when missing.isNotEmpty)
            Text(
              AppLocalizations.of(context)!.downloadTranscodeCodecMaybeUnsupported(missing.join(", ")),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}

/// Codec picker for streaming on backends that don't have Jellyfin's more
/// detailed [StreamingTranscodingFormatDropdownListTile] concept. Currently
/// only Subsonic reads this setting.
class StreamingTranscodeCodecDropdownListTile extends ConsumerWidget {
  const StreamingTranscodeCodecDropdownListTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final codec = ref.watch(finampSettingsProvider.streamingTranscodingCodec);
    return ListTile(
      title: Text(AppLocalizations.of(context)!.streamingTranscodeCodecTitle),
      subtitle: Column(
        spacing: 4.0,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppLocalizations.of(context)!.streamingTranscodeCodecSubtitle),
          FinampSettingsDropdown<FinampTranscodingCodec>(
            dropdownItems: FinampTranscodingCodec.values
                .where((element) => !Platform.isIOS || element.iosCompatible)
                .where((element) => element != FinampTranscodingCodec.original)
                .map((e) {
                  final missing = _sourcesMissingDefaultSupport(e, kind: MediaSourceKind.subsonic).toList();
                  return DropdownMenuEntry<FinampTranscodingCodec>(
                    value: e,
                    label: e.name.toUpperCase(),
                    trailingIcon: missing.isEmpty
                        ? null
                        : Tooltip(
                            message: AppLocalizations.of(
                              context,
                            )!.downloadTranscodeCodecMaybeUnsupported(missing.join(", ")),
                            child: Icon(
                              TablerIcons.alert_triangle,
                              size: 16,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                  );
                })
                .toList(),
            selectedValue: codec,
            onSelected: FinampSetters.setStreamingTranscodingCodec.ifNonNull,
          ),
          if (codec.isLossless)
            Text(
              AppLocalizations.of(context)!.losslessTranscodeStreamingWarning,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          if (_sourcesMissingDefaultSupport(codec, kind: MediaSourceKind.subsonic).toList()
              case final missing when missing.isNotEmpty)
            Text(
              AppLocalizations.of(context)!.downloadTranscodeCodecMaybeUnsupported(missing.join(", ")),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}

class StreamingTranscodingFormatDropdownListTile extends ConsumerWidget {
  const StreamingTranscodingFormatDropdownListTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      title: Text(AppLocalizations.of(context)!.transcodingStreamingFormatTitle),
      subtitle: Column(
        spacing: 4.0,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppLocalizations.of(context)!.transcodingStreamingFormatSubtitle),
          FinampSettingsDropdown<FinampTranscodingStreamingFormat>(
            dropdownItems: FinampTranscodingStreamingFormat.values
                .map(
                  (e) => DropdownMenuEntry<FinampTranscodingStreamingFormat>(
                    value: e,
                    label: "${e.codec}+${e.container}".toUpperCase(),
                  ),
                )
                .toList(),
            selectedValue: ref.watch(finampSettingsProvider.transcodingStreamingFormat),
            onSelected: FinampSetters.setTranscodingStreamingFormat.ifNonNull,
          ),
        ],
      ),
    );
  }
}

class MultichannelHandlingSelector extends ConsumerWidget {
  const MultichannelHandlingSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      title: Text(AppLocalizations.of(context)!.multichannelHandlingTitle),
      subtitle: Column(
        spacing: 4.0,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppLocalizations.of(context)!.multichannelHandlingSubtitle),
          FinampSettingsDropdown<MultichannelHandlingSetting>(
            dropdownItems: MultichannelHandlingSetting.values
                .map(
                  (e) => DropdownMenuEntry<MultichannelHandlingSetting>(
                    value: e,
                    label: AppLocalizations.of(context)!.multichannelHandlingOption(e.name),
                  ),
                )
                .toList(),
            selectedValue: ref.watch(finampSettingsProvider.multichannelHandlingSetting),
            onSelected: FinampSetters.setMultichannelHandlingSetting.ifNonNull,
          ),
        ],
      ),
    );
  }
}

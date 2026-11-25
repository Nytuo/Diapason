import 'package:diapason/components/finamp_app_bar_back_button.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/hifi/hifi_platform.dart';
import 'package:diapason/services/hifi/mpv_output.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bit-perfect output, exclusive mode, output device (mpv) and DSD playback. See `docs/HIFI_AUDIO.md`.
class HifiSettingsScreen extends ConsumerWidget {
  const HifiSettingsScreen({super.key});
  static const routeName = "/settings/hifi";

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final backend = currentHifiBackend;
    final supported = backend != HifiBackend.none;
    final bitPerfect = ref.watch(finampSettingsProvider.hifiBitPerfect);
    final platformNote = switch (backend) {
      HifiBackend.mpv => l10n.hifiPlatformMpv,
      HifiBackend.coreAudio => l10n.hifiPlatformMacos,
      HifiBackend.androidMixer => l10n.hifiPlatformAndroid,
      HifiBackend.none => l10n.hifiPlatformNone,
    };
    final dsdMode = ref.watch(finampSettingsProvider.hifiDsdMode);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.hifiSettingsTitle), leading: FinampAppBarBackButton()),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 200.0),
        children: [
          SwitchListTile.adaptive(
            title: Text(l10n.hifiBitPerfectTitle),
            subtitle: Text(l10n.hifiBitPerfectSubtitle),
            value: supported && bitPerfect,
            onChanged: supported ? FinampSetters.setHifiBitPerfect : null,
          ),
          ListTile(leading: Icon(supported ? Icons.info_outline : Icons.block), subtitle: Text(platformNote)),
          if (backend == HifiBackend.mpv || backend == HifiBackend.coreAudio)
            SwitchListTile.adaptive(
              title: Text(l10n.hifiExclusiveTitle),
              subtitle: Text(l10n.hifiExclusiveSubtitle),
              value: ref.watch(finampSettingsProvider.hifiExclusive),
              onChanged: bitPerfect ? FinampSetters.setHifiExclusive : null,
            ),
          if (backend == HifiBackend.mpv) _OutputDeviceTile(enabled: bitPerfect),
          const Divider(),
          ListTile(title: Text(l10n.hifiDsdTitle)),
          RadioGroup<String>(
            groupValue: dsdMode,
            onChanged: (value) {
              if (value != null) FinampSetters.setHifiDsdMode(value);
            },
            child: Column(
              children: [
                RadioListTile<String>(
                  value: "dop",
                  title: Text(l10n.hifiDsdDop),
                  subtitle: Text(l10n.hifiDsdDopSubtitle),
                ),
                RadioListTile<String>(
                  value: "pcm",
                  title: Text(l10n.hifiDsdPcm),
                  subtitle: Text(l10n.hifiDsdPcmSubtitle),
                ),
              ],
            ),
          ),
          const Divider(),
          ListTile(leading: const Icon(Icons.timeline), subtitle: Text(l10n.hifiSignalPathHint)),
        ],
      ),
    );
  }
}

class _OutputDeviceTile extends ConsumerWidget {
  const _OutputDeviceTile({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final current = ref.watch(finampSettingsProvider.hifiOutputDevice);
    final devices = MpvHifiOutput.devices().where((d) => d.name != "auto").toList();
    final currentLabel = current.isEmpty
        ? l10n.hifiOutputDeviceDefault
        : devices.where((d) => d.name == current).firstOrNull?.description ?? current;
    return ListTile(
      enabled: enabled,
      title: Text(l10n.hifiOutputDeviceTitle),
      subtitle: Text(currentLabel),
      trailing: const Icon(Icons.arrow_drop_down),
      onTap: () async {
        final picked = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(l10n.hifiOutputDeviceTitle),
            children: [
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, ""),
                child: Text(l10n.hifiOutputDeviceDefault),
              ),
              if (devices.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text(l10n.hifiOutputDeviceEmpty)),
              for (final device in devices)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, device.name),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(device.description.isEmpty ? device.name : device.description),
                    subtitle: Text(device.name),
                    selected: device.name == current,
                  ),
                ),
            ],
          ),
        );
        if (picked != null) FinampSetters.setHifiOutputDevice(picked);
      },
    );
  }
}

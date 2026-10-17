import 'package:diapason/services/backends/media_source_service.dart';
import 'package:diapason/services/connect/connect_service.dart';
import 'package:diapason/services/tv/tv_profile_service.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

/// While it is on screen the TV takes accounts sent from a phone (see `ConnectService.sendSources`): it asks the
/// person holding the remote, then adds them to the profile the phone named. Wrap the TV's start screens in it.
class TvSourceOfferListener extends StatefulWidget {
  const TvSourceOfferListener({super.key, required this.child, this.onImported});

  final Widget child;

  /// Called after accounts were added.
  final VoidCallback? onImported;

  @override
  State<TvSourceOfferListener> createState() => _TvSourceOfferListenerState();
}

class _TvSourceOfferListenerState extends State<TvSourceOfferListener> {
  bool _asking = false;

  ConnectService? get _connect =>
      GetIt.instance.isRegistered<ConnectService>() ? GetIt.instance<ConnectService>() : null;

  @override
  void initState() {
    super.initState();
    _connect?.acceptSources = true;
    _connect?.sourceOffer.addListener(_onOffer);
  }

  @override
  void dispose() {
    _connect?.sourceOffer.removeListener(_onOffer);
    _connect?.acceptSources = false;
    super.dispose();
  }

  Future<void> _onOffer() async {
    final offer = _connect?.sourceOffer.value;
    if (offer == null || _asking || !mounted) return;
    _asking = true;
    final accepted =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("Add accounts from your phone?"),
            content: Text(
              "${offer.from.isEmpty ? "A device" : offer.from} wants to add ${offer.sources.length} "
              "account(s) to the profile \"${offer.profileName}\":\n"
              "${offer.sources.map((s) => "• ${s["name"] ?? s["publicAddress"]}").join("\n")}",
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Refuse")),
              FilledButton(autofocus: true, onPressed: () => Navigator.pop(context, true), child: const Text("Add")),
            ],
          ),
        ) ??
        false;
    _connect?.sourceOffer.value = null;
    _asking = false;
    if (!accepted || !mounted) return;

    final sources = GetIt.instance<MediaSourceService>();
    await GetIt.instance<TvProfileService>().importOffer(offer, add: sources.addSource, newId: sources.newSourceId);
    widget.onImported?.call();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

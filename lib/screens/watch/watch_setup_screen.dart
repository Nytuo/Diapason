import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/screens/login_screen.dart';
import 'package:diapason/screens/watch/watch_screen.dart';
import 'package:diapason/screens/watch/watch_widgets.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:diapason/services/connect/watch_connect_controller.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

final _log = Logger("WatchSetup");

/// Gives the watch accounts of its own, to browse music without relying on the device's library: sent from a phone
/// over Diapason Connect (the watch shows up in the phone's device list while this page is open), or signed in here.
class WatchSetupScreen extends StatefulWidget {
  const WatchSetupScreen({super.key});

  @override
  State<WatchSetupScreen> createState() => _WatchSetupScreenState();
}

class _WatchSetupScreenState extends State<WatchSetupScreen> {
  WatchConnectController get _watch => GetIt.instance<WatchConnectController>();
  ValueListenable<SourceOffer?>? _offers;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    if (!GetIt.instance.isRegistered<WatchConnectController>()) return;
    _offers = _watch.startReceivingAccounts()..addListener(_onOffer);
  }

  @override
  void dispose() {
    _offers?.removeListener(_onOffer);
    if (_offers != null) _watch.stopReceivingAccounts();
    super.dispose();
  }

  int get _accountCount =>
      GetIt.instance.isRegistered<BackendRegistry>() ? GetIt.instance<BackendRegistry>().configured.length : 0;

  Future<void> _onOffer() async {
    final offer = _offers?.value;
    if (offer == null || _asking || !mounted) return;
    _asking = true;
    final l10n = AppLocalizations.of(context)!;
    final accepted = await pushWatchPage<bool>(
      context,
      WatchListPage(
        title: l10n.watchOfferTitle,
        children: [
          WatchMessage(
            l10n.watchOfferBody(offer.from.isEmpty ? l10n.watchAnotherDevice : offer.from, offer.sources.length),
          ),
          for (final s in offer.sources) WatchMessage("${s["name"] ?? s["publicAddress"] ?? ""}"),
          Builder(
            builder: (context) => WatchTile(
              icon: TablerIcons.check,
              title: l10n.watchOfferAdd,
              onTap: () => Navigator.of(context).pop(true),
            ),
          ),
          Builder(
            builder: (context) => WatchTile(
              icon: TablerIcons.x,
              title: l10n.watchOfferRefuse,
              onTap: () => Navigator.of(context).pop(false),
            ),
          ),
        ],
      ),
    );
    _asking = false;
    if (!mounted) return;
    if (accepted != true) {
      _watch.declineOffer();
      return;
    }
    try {
      final added = await _watch.importOffer(offer);
      if (mounted) {
        watchToast(context, l10n.watchOfferAdded(added));
        setState(() {});
      }
    } catch (e, stack) {
      final message = FriendlyError.report(_log, "Adding accounts sent to the watch", e, stack);
      if (mounted) watchToast(context, message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return WatchListPage(
      title: l10n.watchSetUp,
      children: [
        WatchMessage(l10n.watchSetupAccounts(_accountCount)),
        const Padding(
          padding: EdgeInsets.all(6.0),
          child: Center(child: Icon(TablerIcons.device_mobile_share, color: WatchColors.accent, size: 28.0)),
        ),
        WatchMessage(l10n.watchSetupReceiveHint),
        WatchTile(
          icon: TablerIcons.login,
          title: l10n.watchSetupSignIn,
          onTap: () async {
            await Navigator.of(context).pushNamed(LoginScreen.routeName);
            if (mounted) setState(() {});
          },
        ),
        WatchMessage(l10n.watchSetupOptional),
      ],
    );
  }
}

import 'package:diapason/components/Buttons/cta_medium.dart';
import 'package:diapason/components/Buttons/simple_button.dart';
import 'package:diapason/components/finamp_app_bar_back_button.dart';
import 'package:diapason/components/NetworkSettingsScreen/active_network_display.dart';
import 'package:diapason/components/NetworkSettingsScreen/auto_offline_selector.dart';
import 'package:diapason/components/NetworkSettingsScreen/prefer_local_network_address_selector.dart';
import 'package:diapason/components/NetworkSettingsScreen/prefer_local_network_selector.dart';
import 'package:diapason/components/NetworkSettingsScreen/public_address_selector.dart';
import 'package:diapason/components/global_snackbar.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/services/jellyfin_api_helper.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/finamp_user_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class NetworkSettingsScreen extends StatefulWidget {
  const NetworkSettingsScreen({super.key});
  static const routeName = "/settings/network";

  @override
  State<NetworkSettingsScreen> createState() => _NetworkSettingsScreenState();
}

class _NetworkSettingsScreenState extends State<NetworkSettingsScreen> {
  final GlobalKey<LocalNetworkAddressSelectorState> localNetworkAddressKey = GlobalKey(
    debugLabel: "localNetworkAddressKey",
  );

  @override
  Widget build(BuildContext context) {
    final hasJellyfinServer = GetIt.instance<FinampUserHelper>().currentUser != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context)!.networkSettingsTitle),
        leading: FinampAppBarBackButton(),
        actions: [
          FinampSettingsHelper.makeSettingsResetButtonWithDialog(context, FinampSettingsHelper.resetNetworkSettings),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 200.0),
        children: [
          if (!hasJellyfinServer)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(TablerIcons.alert_triangle, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 12.0),
                  Expanded(
                    child: Text(
                      "No Jellyfin server configured. The address fields below only apply to Jellyfin — "
                      "other sources have their own local/public address in Sources settings.",
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                ],
              ),
            ),
          AutoOfflineSelector(),
          Divider(),
          if (hasJellyfinServer) ...[
            ActiveNetworkDisplay(),
            PublicAddressSelector(),
            LocalNetworkSelector(),
            LocalNetworkAddressSelector(key: localNetworkAddressKey),
            SizedBox(height: 32.0),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CTAMedium(
                  text: AppLocalizations.of(context)!.testConnectionButtonLabel,
                  icon: TablerIcons.plug_connected,
                  onPressed: () async {
                    final widgetState = localNetworkAddressKey.currentState;
                    if (widgetState != null) {
                      await widgetState.commitIfChanged();
                    }
                    final [public, private] = await Future.wait([
                      GetIt.instance<JellyfinApiHelper>().pingPublicServer(),
                      GetIt.instance<JellyfinApiHelper>().pingLocalServer(),
                    ]);
                    GlobalSnackbar.message(
                      (context) => AppLocalizations.of(context)!.ping("${public.toString()}_${private.toString()}"),
                    );
                  },
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

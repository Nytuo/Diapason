import 'dart:io';

import 'package:diapason/services/connect/connect_models.dart';
import 'package:diapason/services/connect/connect_service.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/uploader/uploader_discovery_service.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

/// Enforces the "No network at all" setting for everything that goes through `dart:io`'s [HttpClient] (which is what
/// `package:http`, chopper, image loading and the backends use).
///
/// It works through [HttpOverrides.findProxyFromEnvironment], which every client that doesn't set its own `findProxy`
/// asks for each request: while the switch is on, every non-loopback request is sent to a proxy address nothing
/// listens on, so it fails at once and never leaves the device. Loopback stays reachable (the audio player's local
/// proxy, local servers on this machine).
///
/// Not covered (stopped by the switch where they start instead): native players (they only play downloaded files
/// while offline mode is on), and raw sockets (mDNS discovery, Diapason Connect).
class NoNetworkGuard extends HttpOverrides {
  NoNetworkGuard._();

  static final _log = Logger("NoNetworkGuard");

  /// Unused port on loopback: connecting to it is refused immediately.
  static const _blackhole = "PROXY 127.0.0.1:9";

  static bool get active {
    try {
      return FinampSettingsHelper.finampSettings.noNetwork;
    } catch (_) {
      return false; // settings not loaded yet (very early start-up)
    }
  }

  /// Applies the switch to the parts the HTTP guard can't reach. Called at start-up and when the setting changes.
  static Future<void> apply(bool on) async {
    if (on) {
      _log.info("No network mode on: offline mode forced, Connect and discovery stopped");
      if (!FinampSettingsHelper.finampSettings.isOffline) FinampSetters.setIsOffline(true);
      if (GetIt.instance.isRegistered<ConnectService>()) await GetIt.instance<ConnectService>().stop();
      if (GetIt.instance.isRegistered<UploaderDiscoveryService>()) {
        await GetIt.instance<UploaderDiscoveryService>().stop();
      }
    } else {
      _log.info("No network mode off");
      if (GetIt.instance.isRegistered<ConnectService>()) {
        final connect = GetIt.instance<ConnectService>();
        try {
          // A watch only advertises while waiting for accounts, so it comes back unadvertised.
          await connect.start(
            deviceName: connect.deviceName,
            role: connect.role,
            advertise: connect.role == ConnectDevice.rolePlayer,
          );
        } catch (e, stack) {
          _log.severe("Could not restart Diapason Connect", e, stack);
        }
      }
    }
  }

  /// Turns the switch on or off from the settings.
  static Future<void> setEnabled(bool on) async {
    FinampSetters.setNoNetwork(on);
    await apply(on);
  }

  static void install() {
    HttpOverrides.global = NoNetworkGuard._();
  }

  static bool isLoopback(String host) {
    final h = host.toLowerCase();
    if (h == "localhost" || h.endsWith(".localhost")) return true;
    final address = InternetAddress.tryParse(h.startsWith("[") ? h.substring(1, h.length - 1) : h);
    return address != null && address.isLoopback;
  }

  /// True when a request to [url] must be refused right now.
  static bool blocks(Uri url) => active && !isLoopback(url.host);

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    if (blocks(url)) {
      _log.fine("Blocked a request to ${url.host} (no network mode)");
      return _blackhole;
    }
    return super.findProxyFromEnvironment(url, environment);
  }
}

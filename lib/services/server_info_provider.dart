import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/finamp_user_helper.dart';
import 'package:diapason/services/jellyfin_api_helper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

import '../components/global_snackbar.dart';

final serverInfoProviderLogger = Logger("ServerInfoProvider");

enum ServerFeature { lyrics }

abstract class PluginInterface {
  String get name;
  String get version;
}

class ServerInfo {
  final PublicSystemInfoResult publicServerInfo;
  final List<UserDto> users;
  final Set<ServerFeature> supportedFeatures;
  final Set<PluginInterface> availablePlugins;

  ServerInfo({
    required this.publicServerInfo,
    this.users = const [],
    this.supportedFeatures = const {},
    this.availablePlugins = const {},
  });

  String get version => publicServerInfo.version ?? GlobalSnackbar.requireL10n.unknownVersion;

  @override
  String toString() {
    return "ServerInfo(publicServerInfo: $publicServerInfo, users: $users, features: $supportedFeatures, plugins: ${availablePlugins.map((p) => p.toString()).join(", ")})";
  }
}

final AsyncNotifierProviderFamily<ServerInfoNotifier, ServerInfo?, Uri> serverInfoProvider = AsyncNotifierProvider
    .autoDispose
    .family<ServerInfoNotifier, ServerInfo?, Uri>(ServerInfoNotifier.new);

/// Provider for info about the currently connected server
final currentServerInfoProvider = Provider<AsyncValue<ServerInfo?>>((ref) {
  final currentServer = ref.watch(FinampUserHelper.finampCurrentUserProvider)?.baseURL;
  if (currentServer != null) {
    return ref.watch(serverInfoProvider(Uri.parse(currentServer)));
  }
  return const AsyncValue.data(null);
});

/// Backs [serverInfoProvider]. A notifier so the last known value can be returned while offline.
class ServerInfoNotifier extends AsyncNotifier<ServerInfo?> {
  ServerInfoNotifier(this.serverAddress);

  final Uri serverAddress;

  /// The value from before this rebuild, used as the offline fallback.
  ServerInfo? get _lastKnown {
    try {
      return state.value;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<ServerInfo?> build() => _fetchServerInfo(ref, serverAddress, _lastKnown);
}

Future<ServerInfo?> _fetchServerInfo(Ref ref, Uri serverAddress, ServerInfo? lastKnown) async {
  final jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();

  final currentUserInfo = ref.watch(FinampUserHelper.finampCurrentUserProvider);
  final bool isCurrentServer = [
    currentUserInfo?.publicAddress,
    currentUserInfo?.localAddress,
  ].contains(serverAddress.toString());
  ServerInfo serverInfo;
  serverInfoProviderLogger.finer("Fetching server info for '$serverAddress'");

  //!!! return last-known value if offline, instead of making a network request
  if (ref.watch(finampSettingsProvider.isOffline)) {
    return lastKnown;
  }

  PublicSystemInfoResult? publicInfo;
  try {
    if (isCurrentServer) {
      publicInfo = await jellyfinApiHelper.loadServerPublicInfo();
    } else {
      publicInfo = await jellyfinApiHelper.loadCustomServerPublicInfo(serverAddress);
    }
    if (publicInfo == null) {
      throw Exception("Received null public server info");
    }
  } catch (e) {
    serverInfoProviderLogger.severe("Failed to fetch public server info for '$serverAddress':", e);
    return null;
  }
  serverInfoProviderLogger.finest("Fetched public server info for '$serverAddress': publicInfo");

  List<UserDto> users = [];
  try {
    final publicUsers = await jellyfinApiHelper.loadPublicUsers();
    users = publicUsers.users;
  } catch (e) {
    serverInfoProviderLogger.severe("Failed to fetch users for '$serverAddress':", e);
  }
  serverInfoProviderLogger.finest("Fetched users for '$serverAddress': $users");

  //TODO implement feature and plugin detection

  serverInfo = ServerInfo(publicServerInfo: publicInfo, users: users);
  serverInfoProviderLogger.fine("Server info for '$serverAddress': $serverInfo");

  return serverInfo;
}

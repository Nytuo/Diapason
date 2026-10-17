import 'dart:math';

import 'package:diapason/models/media_source.dart';
import 'package:diapason/models/tv_profile.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:logging/logging.dart';

/// Where profiles are kept: strings by key. Hive in the app, a map in tests.
abstract interface class TvProfileStore {
  Iterable<String> get keys;
  String? get(String key);
  Future<void> put(String key, String value);
  Future<void> delete(String key);
}

class HiveTvProfileStore implements TvProfileStore {
  HiveTvProfileStore(this._box);

  final Box<String> _box;

  @override
  Iterable<String> get keys => _box.keys.cast<String>();

  @override
  String? get(String key) => _box.get(key);

  @override
  Future<void> put(String key, String value) => _box.put(key, value);

  @override
  Future<void> delete(String key) => _box.delete(key);
}

/// What the profiles need from the media sources, so they can be tested without the whole backend stack.
abstract interface class TvProfileSources {
  List<MediaSourceConfig> get sources;

  /// Saves [config] (with its new `enabled` flag) and makes the running backend reflect it.
  Future<void> setEnabled(MediaSourceConfig config, bool enabled);
}

/// The people who use this TV, and which one is listening now.
///
/// Profiles live in a small Hive box (`TvProfiles`: one JSON string per profile, plus the active id). Choosing a
/// profile turns its sources on and every other source off, so the library, search and playback only see that
/// person's accounts. Sources added while a profile is active become that profile's.
class TvProfileService extends ChangeNotifier {
  TvProfileService(this._box, this._sources);

  factory TvProfileService.hive(Box<String> box, TvProfileSources sources) =>
      TvProfileService(HiveTvProfileStore(box), sources);

  static final _log = Logger("TvProfileService");

  static const boxName = "TvProfiles";
  static const _activeKey = "_active";
  static const _maxProfiles = 8;

  final TvProfileStore _box;
  final TvProfileSources _sources;

  List<TvProfile> get profiles =>
      _box.keys.where((k) => k != _activeKey).map((k) => TvProfile.decode(_box.get(k)!)).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  TvProfile? get active {
    final id = _box.get(_activeKey);
    return id == null ? null : _get(id);
  }

  bool get canAddMore => profiles.length < _maxProfiles;

  TvProfile? _get(String id) {
    final json = _box.get(id);
    return json == null ? null : TvProfile.decode(json);
  }

  /// First launch after profiles were introduced: everything that is already set up becomes one profile, so nothing
  /// disappears. A fresh install gets no profile until someone adds an account.
  Future<void> adoptExistingSources({String name = "Home"}) async {
    if (profiles.isNotEmpty) return;
    final existing = _sources.sources.where((s) => s.kind.isConfigurable).map((s) => s.sourceId).toList();
    if (existing.isEmpty) return;
    final profile = await create(name, sourceIds: existing);
    await select(profile.id);
  }

  /// For trying the profile screens without typing in real accounts (debug builds with
  /// `--dart-define=DIAPASON_DEMO_PROFILES=true`): three empty profiles, if there are none yet.
  Future<void> seedDemoProfiles() async {
    if (profiles.isNotEmpty) return;
    for (final name in ["Alex", "Sam", "Maya"]) {
      await create(name);
    }
  }

  Future<TvProfile> create(String name, {List<String> sourceIds = const []}) async {
    final trimmed = name.trim().isEmpty ? "Profile ${profiles.length + 1}" : name.trim();
    final colors = TvProfile.defaultColors;
    final used = profiles.map((p) => p.colorValue).toSet();
    final color = colors.firstWhere((c) => !used.contains(c), orElse: () => colors[profiles.length % colors.length]);
    final profile = TvProfile(id: _newId(), name: trimmed, colorValue: color, sourceIds: sourceIds);
    await _box.put(profile.id, profile.encode());
    _log.info("Created profile '${profile.name}'");
    notifyListeners();
    return profile;
  }

  Future<void> rename(String id, String name) async {
    final profile = _get(id);
    if (profile == null || name.trim().isEmpty) return;
    await _box.put(id, profile.copyWith(name: name.trim()).encode());
    notifyListeners();
  }

  Future<void> recolor(String id, int colorValue) async {
    final profile = _get(id);
    if (profile == null) return;
    await _box.put(id, profile.copyWith(colorValue: colorValue).encode());
    notifyListeners();
  }

  /// Removes a profile. Its accounts go with it unless another profile also uses them.
  Future<void> delete(String id) async {
    final profile = _get(id);
    if (profile == null) return;
    await _box.delete(id);
    if (_box.get(_activeKey) == id) await _box.delete(_activeKey);
    _log.info("Deleted profile '${profile.name}'");
    notifyListeners();
  }

  /// Makes [id] the listening profile and shows only its sources.
  Future<void> select(String id) async {
    final profile = _get(id);
    if (profile == null) return;
    await _box.put(_activeKey, id);
    for (final source in _sources.sources.where((s) => s.kind.isConfigurable)) {
      final wanted = profile.sourceIds.contains(source.sourceId);
      if (source.enabled != wanted) await _sources.setEnabled(source, wanted);
    }
    _log.info("Switched to profile '${profile.name}' (${profile.sourceIds.length} source(s))");
    notifyListeners();
  }

  /// Takes accounts another device sent: they go into the profile named in the [offer] (made if it is new), which
  /// becomes the listening one. An account the TV already has for the same server and user is not duplicated, only
  /// shared with the profile. Returns how many accounts were added.
  Future<int> importOffer(
    SourceOffer offer, {
    required Future<void> Function(MediaSourceConfig config) add,
    required String Function(MediaSourceKind kind) newId,
  }) async {
    final wanted = offer.profileName.trim().toLowerCase();
    var profile = profiles.where((p) => p.name.toLowerCase() == wanted).firstOrNull;
    profile ??= await create(offer.profileName);
    await select(profile.id);

    var added = 0;
    for (final json in offer.sources) {
      final MediaSourceConfig incoming;
      try {
        incoming = MediaSourceConfig.fromTvOSStorageJson(json);
      } catch (e) {
        _log.warning("Ignored a malformed account from ${offer.from}: $e");
        continue;
      }
      if (!incoming.kind.isConfigurable || incoming.kind == MediaSourceKind.local) continue;

      final same = _sources.sources
          .where(
            (s) =>
                s.kind == incoming.kind && s.publicAddress == incoming.publicAddress && s.username == incoming.username,
          )
          .firstOrNull;
      if (same != null) {
        await attachSource(same.sourceId);
        if (!same.enabled) await _sources.setEnabled(same, true);
        continue;
      }

      final config = MediaSourceConfig(
        sourceId: newId(incoming.kind),
        kind: incoming.kind,
        name: incoming.name,
        publicAddress: incoming.publicAddress,
        localAddress: incoming.localAddress,
        preferLocalNetwork: incoming.preferLocalNetwork,
        isLocal: incoming.isLocal,
        accessToken: incoming.accessToken,
        username: incoming.username,
        password: incoming.password,
        userId: incoming.userId,
      );
      await add(config);
      added++;
    }
    notifyListeners();
    return added;
  }

  /// A new account belongs to whoever is listening.
  Future<void> attachSource(String sourceId) async {
    final profile = active;
    if (profile == null || profile.sourceIds.contains(sourceId)) return;
    await _box.put(profile.id, profile.copyWith(sourceIds: [...profile.sourceIds, sourceId]).encode());
    notifyListeners();
  }

  /// An account that was removed has to leave every profile that listed it.
  Future<void> detachSource(String sourceId) async {
    for (final profile in profiles.where((p) => p.sourceIds.contains(sourceId))) {
      await _box.put(
        profile.id,
        profile.copyWith(sourceIds: profile.sourceIds.where((s) => s != sourceId).toList()).encode(),
      );
    }
    notifyListeners();
  }

  /// Sources the given profile owns, as configs (for showing them).
  List<MediaSourceConfig> sourcesOf(TvProfile profile) =>
      _sources.sources.where((s) => profile.sourceIds.contains(s.sourceId)).toList();

  static String _newId() {
    final rng = Random.secure();
    return List.generate(10, (_) => rng.nextInt(36).toRadixString(36)).join();
  }
}

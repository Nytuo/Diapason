import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/stream_cache_service.dart';
import 'package:file_sizes/file_sizes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';

class CacheSettingsScreen extends ConsumerStatefulWidget {
  const CacheSettingsScreen({super.key});

  static const routeName = "/settings/cache";

  @override
  ConsumerState<CacheSettingsScreen> createState() => _CacheSettingsScreenState();
}

class _CacheSettingsScreenState extends ConsumerState<CacheSettingsScreen> {
  StreamCacheService get _cache => GetIt.instance<StreamCacheService>();

  Future<int> _size = Future.value(0);

  static const _sizeOptions = [256, 512, 1024, 2048, 4096, 8192];

  @override
  void initState() {
    super.initState();
    _refreshSize();
  }

  void _refreshSize() {
    setState(() {
      _size = _cache.currentSizeBytes();
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(finampSettingsProvider.cacheStreamedTracks);
    final maxMegabytes = ref.watch(finampSettingsProvider.maxCacheSizeMegabytes);

    return Scaffold(
      appBar: AppBar(title: const Text("Cache")),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text("Cache streamed tracks"),
            subtitle: const Text(
              "Keep a copy of tracks as they play, so replaying one doesn't download it again",
            ),
            value: enabled,
            onChanged: (value) => FinampSetters.setCacheStreamedTracks(value),
          ),
          ListTile(
            enabled: enabled,
            title: const Text("Maximum size"),
            subtitle: const Text("The oldest tracks are removed once the cache is full"),
            trailing: DropdownButton<int>(
              value: _sizeOptions.contains(maxMegabytes) ? maxMegabytes : _sizeOptions.last,
              onChanged: enabled
                  ? (value) {
                      if (value != null) FinampSetters.setMaxCacheSizeMegabytes(value);
                    }
                  : null,
              items: [
                for (final megabytes in _sizeOptions)
                  DropdownMenuItem(
                    value: megabytes,
                    child: Text(FileSize.getSize(megabytes * 1024 * 1024, precision: PrecisionValue.None)),
                  ),
              ],
            ),
          ),
          const Divider(),
          FutureBuilder<int>(
            future: _size,
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              return ListTile(
                title: const Text("Currently cached"),
                subtitle: Text(bytes == null ? "Calculating…" : FileSize.getSize(bytes)),
                trailing: TextButton(
                  onPressed: (bytes ?? 0) == 0
                      ? null
                      : () async {
                          await _cache.clear();
                          _refreshSize();
                        },
                  child: const Text("Clear"),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

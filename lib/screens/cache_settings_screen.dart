import 'package:diapason/l10n/app_localizations.dart';
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
      appBar: AppBar(title: Text(AppLocalizations.of(context)!.cacheTitle)),
      body: ListView(
        children: [
          SwitchListTile(
            title: Text(AppLocalizations.of(context)!.cacheStreamed),
            subtitle: Text(AppLocalizations.of(context)!.cacheStreamedSubtitle),
            value: enabled,
            onChanged: (value) => FinampSetters.setCacheStreamedTracks(value),
          ),
          ListTile(
            enabled: enabled,
            title: Text(AppLocalizations.of(context)!.cacheMaxSize),
            subtitle: Text(AppLocalizations.of(context)!.cacheMaxSizeSubtitle),
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
                title: Text(AppLocalizations.of(context)!.cacheCurrentlyCached),
                subtitle: Text(
                  bytes == null ? AppLocalizations.of(context)!.cacheCalculating : FileSize.getSize(bytes),
                ),
                trailing: TextButton(
                  onPressed: (bytes ?? 0) == 0
                      ? null
                      : () async {
                          await _cache.clear();
                          _refreshSize();
                        },
                  child: Text(AppLocalizations.of(context)!.cacheClear),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

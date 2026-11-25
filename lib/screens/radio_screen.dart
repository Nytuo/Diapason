import 'package:diapason/screens/desktop/desktop_router.dart';
import 'dart:async';

import 'package:diapason/components/Radio/radio_station_tile.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/models/radio_station.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/friendly_error.dart';
import 'package:diapason/services/radio/radio_browser_client.dart';
import 'package:diapason/services/radio/radio_station_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

final _log = Logger("RadioScreen");

/// Internet radio: the user's stations, the Radio Browser directory and the
/// stations configured on their servers.
class RadioScreen extends StatelessWidget {
  const RadioScreen({super.key});

  static const routeName = "/radio";

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.radioStationsTitle),
        actions: [
          IconButton(
            tooltip: l10n.radioStationsAdd,
            icon: const Icon(TablerIcons.plus),
            onPressed: () => showRadioStationDialog(context),
          ),
        ],
      ),
      body: const RadioStationsView(),
    );
  }
}

/// The radio tabs without a Scaffold, so the desktop shell can embed them.
class RadioStationsView extends ConsumerWidget {
  const RadioStationsView({super.key, this.showAddButton = false});

  /// Adds an "Add station" button next to the tabs (desktop has no app bar).
  final bool showAddButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final offline = ref.watch(finampSettingsProvider.isOffline);
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          if (offline)
            MaterialBanner(
              leading: const Icon(TablerIcons.wifi_off),
              content: Text(l10n.radioStationsOffline),
              actions: const [SizedBox.shrink()],
            ),
          Row(
            children: [
              Expanded(
                child: TabBar(
                  tabs: [
                    Tab(text: l10n.radioStationsTabMine),
                    Tab(text: l10n.radioStationsTabBrowse),
                    Tab(text: l10n.radioStationsTabSearch),
                  ],
                ),
              ),
              if (showAddButton)
                IconButton(
                  tooltip: l10n.radioStationsAdd,
                  icon: const Icon(TablerIcons.plus),
                  onPressed: () => showRadioStationDialog(context),
                ),
            ],
          ),
          const Expanded(child: TabBarView(children: [_MyStationsTab(), _BrowseTab(), _SearchTab()])),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text, {this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
    child: Row(
      children: [
        Expanded(child: Text(text, style: Theme.of(context).textTheme.titleSmall)),
        ?trailing,
      ],
    ),
  );
}

class _MyStationsTab extends ConsumerStatefulWidget {
  const _MyStationsTab();

  @override
  ConsumerState<_MyStationsTab> createState() => _MyStationsTabState();
}

class _MyStationsTabState extends ConsumerState<_MyStationsTab> with AutomaticKeepAliveClientMixin {
  late Future<List<BaseItemDto>> _serverStations = _loadServerStations();

  Future<List<BaseItemDto>> _loadServerStations() async {
    try {
      return await GetIt.instance<AggregateBackend>().getRadioStations();
    } catch (e, stack) {
      FriendlyError.report(_log, "Load the servers' radio stations", e, stack);
      return const [];
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final saved = ref.watch(savedRadioStationsProvider).value ?? const [];
    final savedIds = saved.map((s) => s.id).toSet();
    final recent = (ref.watch(recentRadioStationsProvider).value ?? const [])
        .where((s) => !savedIds.contains(s.id))
        .toList();

    return RefreshIndicator(
      onRefresh: () async {
        setState(() => _serverStations = _loadServerStations());
        await _serverStations;
      },
      child: FutureBuilder<List<BaseItemDto>>(
        future: _serverStations,
        builder: (context, snapshot) {
          final server = snapshot.data ?? const [];
          final empty = saved.isEmpty && recent.isEmpty && server.isEmpty;
          return ListView(
            children: [
              if (empty && snapshot.connectionState != ConnectionState.waiting)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    children: [
                      Text(l10n.radioStationsEmptyMine, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        icon: const Icon(TablerIcons.plus),
                        label: Text(l10n.radioStationsAdd),
                        onPressed: () => showRadioStationDialog(context),
                      ),
                    ],
                  ),
                ),
              if (saved.isNotEmpty) ...[
                _SectionHeader(l10n.radioStationsSaved),
                for (final station in saved)
                  RadioStationTile(
                    station: station,
                    isSaved: true,
                    onEdit: () => showRadioStationDialog(context, station: station),
                  ),
              ],
              if (recent.isNotEmpty) ...[
                _SectionHeader(
                  l10n.radioStationsRecent,
                  trailing: IconButton(
                    tooltip: l10n.radioStationsClearRecent,
                    icon: const Icon(TablerIcons.clear_all),
                    onPressed: RadioStationStore.clearRecent,
                  ),
                ),
                for (final station in recent) RadioStationTile(station: station),
              ],
              if (snapshot.connectionState == ConnectionState.waiting)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (server.isNotEmpty) ...[
                _SectionHeader(l10n.radioStationsFromServer),
                for (final item in server)
                  ListTile(
                    leading: const RadioStationLogo(),
                    title: Text(item.name ?? "", maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      Uri.tryParse(item.path ?? "")?.host ?? "",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => playRadioItem(context, item),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

enum _BrowseMode { top, trending, countries, languages, tags }

class _BrowseTab extends StatefulWidget {
  const _BrowseTab();

  @override
  State<_BrowseTab> createState() => _BrowseTabState();
}

class _BrowseTabState extends State<_BrowseTab> with AutomaticKeepAliveClientMixin {
  _BrowseMode _mode = _BrowseMode.top;
  final _cache = <_BrowseMode, Future<Object>>{};

  @override
  bool get wantKeepAlive => true;

  Future<Object> _load(_BrowseMode mode) => _cache[mode] ??= switch (mode) {
    _BrowseMode.top => RadioBrowserClient.instance.top(limit: 100),
    _BrowseMode.trending => RadioBrowserClient.instance.trending(limit: 100),
    _BrowseMode.countries => RadioBrowserClient.instance.countries(),
    _BrowseMode.languages => RadioBrowserClient.instance.languages(),
    _BrowseMode.tags => RadioBrowserClient.instance.tags(),
  };

  String _label(AppLocalizations l10n, _BrowseMode mode) => switch (mode) {
    _BrowseMode.top => l10n.radioStationsTop,
    _BrowseMode.trending => l10n.radioStationsTrending,
    _BrowseMode.countries => l10n.radioStationsCountries,
    _BrowseMode.languages => l10n.radioStationsLanguages,
    _BrowseMode.tags => l10n.radioStationsTags,
  };

  void _openCategory(RadioBrowserCategory category) {
    final title = category.name;
    final Future<List<RadioStation>> Function() load = switch (_mode) {
      _BrowseMode.countries => () => RadioBrowserClient.instance.search(countryCode: category.code, limit: 200),
      _BrowseMode.languages => () => RadioBrowserClient.instance.search(language: category.name, limit: 200),
      _ => () => RadioBrowserClient.instance.search(tag: category.name, limit: 200),
    };
    DesktopRouter.pushPage<void>(
      context,
      (_) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: _StationList(load: load),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              for (final mode in _BrowseMode.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(_label(l10n, mode)),
                    selected: _mode == mode,
                    onSelected: (_) => setState(() => _mode = mode),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: switch (_mode) {
            _BrowseMode.top || _BrowseMode.trending => _StationList(
              key: ValueKey(_mode),
              load: () async => await _load(_mode) as List<RadioStation>,
              onRetry: () => _cache.remove(_mode),
            ),
            _ => _CategoryList(
              key: ValueKey(_mode),
              load: () async => await _load(_mode) as List<RadioBrowserCategory>,
              onRetry: () => _cache.remove(_mode),
              onTap: _openCategory,
            ),
          },
        ),
        Padding(
          padding: const EdgeInsets.all(4),
          child: Text(l10n.radioStationsDirectoryCredit, style: Theme.of(context).textTheme.labelSmall),
        ),
      ],
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.radioStationsLoadError(FriendlyError.message(error)), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: Text(l10n.retry)),
          ],
        ),
      ),
    );
  }
}

/// A list of directory stations, loaded by [load].
class _StationList extends ConsumerStatefulWidget {
  const _StationList({super.key, required this.load, this.onRetry});

  final Future<List<RadioStation>> Function() load;
  final VoidCallback? onRetry;

  @override
  ConsumerState<_StationList> createState() => _StationListState();
}

class _StationListState extends ConsumerState<_StationList> {
  late Future<List<RadioStation>> _future = widget.load();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final savedIds = (ref.watch(savedRadioStationsProvider).value ?? const []).map((s) => s.id).toSet();
    return FutureBuilder<List<RadioStation>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          _log.warning("Radio Browser listing failed", snapshot.error);
          return _LoadError(
            error: snapshot.error!,
            onRetry: () {
              widget.onRetry?.call();
              setState(() => _future = widget.load());
            },
          );
        }
        final stations = snapshot.data ?? const [];
        if (stations.isEmpty) return Center(child: Text(l10n.radioStationsNoResults));
        return ListView.builder(
          itemCount: stations.length,
          itemBuilder: (context, i) =>
              RadioStationTile(station: stations[i], isSaved: savedIds.contains(stations[i].id)),
        );
      },
    );
  }
}

class _CategoryList extends StatefulWidget {
  const _CategoryList({super.key, required this.load, required this.onTap, this.onRetry});

  final Future<List<RadioBrowserCategory>> Function() load;
  final ValueChanged<RadioBrowserCategory> onTap;
  final VoidCallback? onRetry;

  @override
  State<_CategoryList> createState() => _CategoryListState();
}

class _CategoryListState extends State<_CategoryList> {
  late Future<List<RadioBrowserCategory>> _future = widget.load();
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return FutureBuilder<List<RadioBrowserCategory>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _LoadError(
            error: snapshot.error!,
            onRetry: () {
              widget.onRetry?.call();
              setState(() => _future = widget.load());
            },
          );
        }
        final query = _filter.text.trim().toLowerCase();
        final categories = (snapshot.data ?? const [])
            .where((c) => c.stationCount > 0 && (query.isEmpty || c.name.toLowerCase().contains(query)))
            .toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _filter,
                decoration: const InputDecoration(prefixIcon: Icon(TablerIcons.filter), isDense: true),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Expanded(
              child: categories.isEmpty
                  ? Center(child: Text(l10n.radioStationsNoResults))
                  : ListView.builder(
                      itemCount: categories.length,
                      itemBuilder: (context, i) {
                        final category = categories[i];
                        return ListTile(
                          title: Text(category.name),
                          trailing: Text(l10n.radioStationsStationCount(category.stationCount)),
                          onTap: () => widget.onTap(category),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _SearchTab extends StatefulWidget {
  const _SearchTab();

  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> with AutomaticKeepAliveClientMixin {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = "";

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(TablerIcons.search),
              hintText: l10n.radioStationsSearchHint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: _onChanged,
            onSubmitted: (value) {
              _debounce?.cancel();
              setState(() => _query = value.trim());
            },
          ),
        ),
        Expanded(
          child: _query.length < 2
              ? const SizedBox.shrink()
              : _StationList(
                  key: ValueKey(_query),
                  load: () => RadioBrowserClient.instance.search(name: _query, limit: 100),
                ),
        ),
      ],
    );
  }
}

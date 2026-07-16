import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/backends/aggregate_backend.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class DesktopFolders extends StatefulWidget {
  const DesktopFolders({super.key});

  @override
  State<DesktopFolders> createState() => _DesktopFoldersState();
}

class _DesktopFoldersState extends State<DesktopFolders> {
  final _backend = GetIt.instance<AggregateBackend>();
  final List<BaseItemDto> _stack = [];
  Future<List<BaseItemDto>>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = _backend.getItems(parentItem: _stack.isEmpty ? null : _stack.last);
  }

  void _open(BaseItemDto item) {
    setState(() {
      _stack.add(item);
      _load();
    });
  }

  void _popTo(int index) {
    setState(() {
      _stack.removeRange(index, _stack.length);
      _load();
    });
  }

  bool _isTrack(BaseItemDto item) => BaseItemDtoType.fromItem(item) == BaseItemDtoType.track;

  Future<void> _playFrom(List<BaseItemDto> siblings, BaseItemDto item) async {
    final tracks = siblings.where(_isTrack).toList();
    final start = tracks.indexWhere((t) => t.id == item.id);
    await GetIt.instance<QueueService>().startPlayback(
      items: tracks,
      source: QueueItemSource.rawId(
        type: QueueItemSourceType.allTracks,
        name: QueueItemSourceName(type: QueueItemSourceNameType.preTranslated, pretranslatedName: _stack.isEmpty ? "Folder" : _stack.last.name),
        id: _stack.isEmpty ? "folders" : _stack.last.id.raw,
      ),
      startingIndex: start < 0 ? 0 : start,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    return Material(
      color: p.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _breadcrumb(p),
          Expanded(
            child: FutureBuilder<List<BaseItemDto>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text("Failed to load folder", style: TextStyle(color: p.textSecondary)));
                }
                final items = snapshot.data ?? [];
                if (items.isEmpty) {
                  return Center(child: Text("Empty folder", style: TextStyle(color: p.textTertiary)));
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final track = _isTrack(item);
                    return ListTile(
                      leading: Icon(
                        track ? TablerIcons.music : TablerIcons.folder,
                        color: track ? p.textSecondary : p.accent,
                      ),
                      title: Text(
                        item.name ?? "Unknown",
                        style: TextStyle(color: p.textPrimary, fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: track ? null : Icon(TablerIcons.chevron_right, size: 18, color: p.textTertiary),
                      onTap: () => track ? _playFrom(items, item) : _open(item),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _breadcrumb(DesktopPalette p) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.borderSubtle))),
      child: Row(
        children: [
          _crumb(p, TablerIcons.home, "Library", () => _popTo(0), _stack.isEmpty),
          for (var i = 0; i < _stack.length; i++) ...[
            Icon(TablerIcons.chevron_right, size: 14, color: p.textTertiary),
            _crumb(p, null, _stack[i].name ?? "…", () => _popTo(i + 1), i == _stack.length - 1),
          ],
        ],
      ),
    );
  }

  Widget _crumb(DesktopPalette p, IconData? icon, String label, VoidCallback onTap, bool active) {
    return TextButton.icon(
      onPressed: onTap,
      icon: icon == null ? const SizedBox.shrink() : Icon(icon, size: 14),
      label: Text(label, style: TextStyle(fontSize: 13, fontWeight: active ? FontWeight.bold : FontWeight.normal)),
      style: TextButton.styleFrom(
        foregroundColor: active ? p.textPrimary : p.textSecondary,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
      ),
    );
  }
}

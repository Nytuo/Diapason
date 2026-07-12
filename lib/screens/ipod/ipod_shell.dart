import 'package:audio_service/audio_service.dart';
import 'package:diapason/components/album_image.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/screens/ipod/click_wheel.dart';
import 'package:diapason/screens/ipod/ipod_controller.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/queue_service.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';

class IpodShell extends ConsumerStatefulWidget {
  const IpodShell({super.key});

  static const routeName = "/ipod";

  @override
  ConsumerState<IpodShell> createState() => _IpodShellState();
}

class _IpodShellState extends ConsumerState<IpodShell> {
  final _controller = IpodController();

  @override
  void initState() {
    super.initState();
    _controller.current.loadIfNeeded();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(finampSettingsProvider.interfaceMode, (_, mode) {
      if (InterfaceMode.fromName(mode) == InterfaceMode.modern && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFF7F7F7), Color(0xFFE5E5E5)],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final screenHeight = constraints.maxHeight * 0.46;
              final wheelDiameter = (width * 0.72).clamp(180.0, 300.0);

              return Column(
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(width * 0.06, 8, width * 0.06, 0),
                    child: SizedBox(
                      height: screenHeight,
                      width: double.infinity,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.black.withValues(alpha: 0.30), width: 2),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.12),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(7),
                          child: AnimatedBuilder(
                            animation: _controller,
                            builder: (context, _) => _IpodDisplay(controller: _controller),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  ClickWheel(controller: _controller, diameter: wheelDiameter),
                  const Spacer(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _IpodDisplay extends StatelessWidget {
  const _IpodDisplay({required this.controller});

  final IpodController controller;

  @override
  Widget build(BuildContext context) {
    final screen = controller.current;

    return ColoredBox(
      color: const Color(0xFFFAFAFA),
      child: Column(
        children: [
          Container(
            height: 26,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFC7D6EB), Color(0xFF9EB3D1)],
              ),
            ),
            child: Text(
              screen.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF262626)),
            ),
          ),
          Expanded(
            child: AnimatedBuilder(
              animation: screen,
              builder: (context, _) =>
                  screen.isNowPlaying ? const _IpodNowPlaying() : _IpodList(screen: screen),
            ),
          ),
        ],
      ),
    );
  }
}

class _IpodList extends StatefulWidget {
  const _IpodList({required this.screen});

  final IpodScreen screen;

  @override
  State<_IpodList> createState() => _IpodListState();
}

class _IpodListState extends State<_IpodList> {
  final _scroll = ScrollController();
  static const _rowHeight = 34.0;

  @override
  void didUpdateWidget(_IpodList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _keepSelectionVisible();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _keepSelectionVisible());
  }

  void _keepSelectionVisible() {
    if (!_scroll.hasClients) return;

    final target = (widget.screen.selection * _rowHeight) - (_scroll.position.viewportDimension / 2) + _rowHeight / 2;
    _scroll.animateTo(
      target.clamp(0.0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = widget.screen;

    if (screen.isLoading) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    if (screen.rows.isEmpty) {
      return const Center(child: Text("Empty", style: TextStyle(fontSize: 13, color: Colors.black54)));
    }

    _keepSelectionVisible();

    return ListView.builder(
      controller: _scroll,
      itemExtent: _rowHeight,
      itemCount: screen.rows.length,
      itemBuilder: (context, index) {
        final row = screen.rows[index];
        final selected = index == screen.selection;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          color: selected ? const Color(0xFF3E7BD1) : Colors.transparent,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                        color: selected ? Colors.white : const Color(0xFF1F1F1F),
                      ),
                    ),
                    if (row.subtitle case final subtitle? when subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: selected ? Colors.white70 : Colors.black54,
                        ),
                      ),
                  ],
                ),
              ),
              if (row.action is IpodPush)
                Icon(
                  Icons.chevron_right,
                  size: 14,
                  color: selected ? Colors.white : Colors.black38,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _IpodNowPlaying extends StatelessWidget {
  const _IpodNowPlaying();

  @override
  Widget build(BuildContext context) {
    final player = GetIt.instance<MusicPlayerBackgroundTask>();

    return StreamBuilder<FinampQueueInfo?>(
      stream: GetIt.instance<QueueService>().getQueueStream(),
      builder: (context, snapshot) {
        final track = snapshot.data?.currentTrack?.baseItem;
        final duration = track?.runTimeTicksDuration() ?? Duration.zero;

        return Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 72,
                height: 72,
                child: AlbumImage(item: track, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 8),
              Text(
                track?.name ?? "Nothing playing",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF1F1F1F)),
              ),
              const SizedBox(height: 2),
              Text(
                track?.albumArtist ?? "",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
              Text(
                track?.album ?? "",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.black38),
              ),

              const SizedBox(height: 12),
              StreamBuilder<PlaybackState>(
                stream: player.playbackState,
                builder: (context, snapshot) {
                  final position = snapshot.data?.position ?? Duration.zero;
                  final progress = duration.inMilliseconds == 0
                      ? 0.0
                      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

                  return Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 5,
                          backgroundColor: Colors.black12,
                          valueColor: const AlwaysStoppedAnimation(Color(0xFF3E7BD1)),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_time(position), style: const TextStyle(fontSize: 10, color: Colors.black54)),
                          Text(_time(duration), style: const TextStyle(fontSize: 10, color: Colors.black54)),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  static String _time(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, "0");
    return "$minutes:$seconds";
  }
}

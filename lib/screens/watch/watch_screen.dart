import 'dart:async';
import 'dart:math' as math;

import 'package:diapason/components/connect_devices.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/screens/watch/watch_library_screen.dart';
import 'package:diapason/screens/watch/watch_rotary.dart';
import 'package:diapason/screens/watch/watch_setup_screen.dart';
import 'package:diapason/screens/watch/watch_widgets.dart';
import 'package:diapason/services/connect/connect_models.dart';
import 'package:diapason/services/connect/watch_connect_controller.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

WatchConnectController get _watch => GetIt.instance<WatchConnectController>();

/// Pushes a watch page; a swipe from the left edge goes back (the system's swipe-to-dismiss is off, see styles.xml).
Future<T?> pushWatchPage<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push<T>(CupertinoPageRoute(builder: (_) => page));

/// The watch app: the devices to pick from until one is controlled, then what it plays.
class WatchScreen extends StatelessWidget {
  const WatchScreen({super.key});

  static const routeName = "/watch";

  @override
  Widget build(BuildContext context) {
    if (!GetIt.instance.isRegistered<WatchConnectController>()) return const WatchDevicesPage();
    return ValueListenableBuilder<ConnectDevice?>(
      valueListenable: _watch.device,
      builder: (context, device, _) => device == null ? const WatchDevicesPage() : const WatchNowPlaying(),
    );
  }
}

/// The players on the network, and set-up.
class WatchDevicesPage extends StatefulWidget {
  const WatchDevicesPage({super.key});

  @override
  State<WatchDevicesPage> createState() => _WatchDevicesPageState();
}

class _WatchDevicesPageState extends State<WatchDevicesPage> {
  ConnectDevice? _connecting;

  @override
  void initState() {
    super.initState();
    if (GetIt.instance.isRegistered<WatchConnectController>() && _watch.device.value == null) {
      unawaited(_watch.rescan());
    }
  }

  Future<void> _pick(ConnectDevice device) async {
    setState(() => _connecting = device);
    final ok = await _watch.select(device);
    if (!mounted) return;
    setState(() => _connecting = null);
    if (!ok) {
      watchToast(context, AppLocalizations.of(context)!.watchCouldNotConnect(connectDisplayName(device.name)));
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (!GetIt.instance.isRegistered<WatchConnectController>()) {
      return WatchListPage(children: [WatchMessage(l10n.watchSearchingDevices)]);
    }
    return AnimatedBuilder(
      animation: Listenable.merge([_watch.players, _watch.device, _watch.reconnecting]),
      builder: (context, _) {
        final current = _watch.device.value;
        final players = _watch.players.value;
        return WatchListPage(
          title: l10n.watchChooseDevice,
          children: [
            if (_watch.reconnecting.value && current == null)
              WatchMessage(l10n.watchReconnecting(connectDisplayName(_watch.rememberedName))),
            for (final device in players)
              WatchTile(
                icon: TablerIcons.device_speaker,
                title: connectDisplayName(device.name),
                selected: device == current,
                leading: device == _connecting
                    ? const SizedBox.square(dimension: 22.0, child: CircularProgressIndicator(strokeWidth: 2.0))
                    : null,
                onTap: _connecting == null ? () => _pick(device) : null,
              ),
            if (players.isEmpty) ...[
              const Padding(
                padding: EdgeInsets.all(8.0),
                child: Center(
                  child: SizedBox.square(dimension: 22.0, child: CircularProgressIndicator(strokeWidth: 2.0)),
                ),
              ),
              WatchMessage(l10n.watchSearchingDevices),
              WatchMessage(l10n.watchNoDevicesHint),
            ],
            const SizedBox(height: 8.0),
            if (current != null)
              WatchTile(
                icon: TablerIcons.plug_connected_x,
                title: l10n.watchDisconnect,
                onTap: () {
                  _watch.forget();
                  if (Navigator.of(context).canPop()) Navigator.of(context).pop();
                },
              ),
            WatchTile(
              icon: TablerIcons.settings,
              title: l10n.watchSetUp,
              onTap: () => pushWatchPage<void>(context, const WatchSetupScreen()),
            ),
          ],
        );
      },
    );
  }
}

/// What the controlled device plays: artwork, title, artist, a progress ring to drag to seek, and the controls. The
/// crown sets the volume.
class WatchNowPlaying extends StatefulWidget {
  const WatchNowPlaying({super.key});

  @override
  State<WatchNowPlaying> createState() => _WatchNowPlayingState();
}

class _WatchNowPlayingState extends State<WatchNowPlaying> {
  Timer? _ticker;
  DateTime _statusAt = DateTime.now();
  ConnectStatus? _status;

  /// Where the finger is on the ring while seeking (0..1).
  double? _dragFraction;

  double? _pendingVolume;
  Timer? _volumeSend;
  Timer? _volumeHide;
  bool _showVolume = false;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _status = _watch.status.value;
    _watch.status.addListener(_onStatus);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_status?.isPlaying ?? false) setState(() {});
    });
  }

  @override
  void dispose() {
    _watch.status.removeListener(_onStatus);
    _ticker?.cancel();
    _volumeSend?.cancel();
    _volumeHide?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onStatus() => setState(() {
    _status = _watch.status.value;
    _statusAt = DateTime.now();
  });

  double get _position {
    final status = _status;
    if (status == null) return 0;
    final elapsed = status.isPlaying ? DateTime.now().difference(_statusAt).inMilliseconds / 1000 : 0;
    final duration = status.song?.duration ?? 0;
    final position = status.position + elapsed;
    return duration > 0 ? position.clamp(0, duration).toDouble() : position;
  }

  double get _volume => _pendingVolume ?? _status?.volume ?? 1.0;

  void _turn(double delta) {
    // About 5% per detent of a typical crown.
    final next = (_volume - delta / 1000).clamp(0.0, 1.0);
    setState(() {
      _pendingVolume = next;
      _showVolume = true;
    });
    _volumeSend ??= Timer(const Duration(milliseconds: 200), () async {
      _volumeSend = null;
      final volume = _pendingVolume;
      if (volume != null) await _watch.setVolume(volume);
    });
    _volumeHide?.cancel();
    _volumeHide = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _showVolume = false);
      _pendingVolume = null;
    });
  }

  double? _ringFraction(Offset local, Size size) {
    final center = size.center(Offset.zero);
    final v = local - center;
    if (v.distance < size.shortestSide / 2 * 0.72) return null;
    final angle = math.atan2(v.dx, -v.dy);
    return (angle < 0 ? angle + 2 * math.pi : angle) / (2 * math.pi);
  }

  Future<void> _command(Future<bool> Function() send) async {
    final ok = await send();
    if (!ok && mounted) watchToast(context, AppLocalizations.of(context)!.watchSendFailed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final status = _status;
    final song = status?.song;
    final duration = song?.duration ?? 0;
    final progress = _dragFraction ?? (duration > 0 ? _position / duration : 0.0);
    final art = song == null ? null : _watch.artFor(song);
    final deviceName = connectDisplayName(_watch.device.value?.name ?? "");

    return Scaffold(
      backgroundColor: WatchColors.background,
      body: WatchRotaryScroll(
        controller: _scroll,
        onTurn: _turn,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            return GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: duration <= 0
                  ? null
                  : (d) => setState(() => _dragFraction = _ringFraction(d.localPosition, size)),
              onPanUpdate: (d) {
                if (_dragFraction == null) return;
                final f = _ringFraction(d.localPosition, size);
                if (f != null) setState(() => _dragFraction = f);
              },
              onPanEnd: (_) {
                final f = _dragFraction;
                setState(() => _dragFraction = null);
                if (f != null && duration > 0) unawaited(_command(() => _watch.seek(f * duration)));
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (art != null)
                    Opacity(
                      opacity: 0.3,
                      child: Image.network(
                        art.toString(),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox(),
                      ),
                    ),
                  CustomPaint(
                    painter: _RingPainter(progress: progress.clamp(0.0, 1.0), dragging: _dragFraction != null),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: size.width * 0.14, vertical: size.height * 0.1),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        GestureDetector(
                          onTap: () => pushWatchPage<void>(context, const WatchDevicesPage()),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(TablerIcons.device_speaker, size: 12.0, color: WatchColors.accent),
                              const SizedBox(width: 3.0),
                              Flexible(
                                child: Text(
                                  deviceName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: WatchColors.accent, fontSize: 11.0),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4.0),
                        if (_dragFraction case final f?)
                          Text(
                            "${_clock(f * duration)} / ${_clock(duration)}",
                            style: const TextStyle(color: WatchColors.text, fontSize: 13.0),
                          )
                        else if (_showVolume)
                          Text(
                            "${l10n.watchVolume} ${(_volume * 100).round()}%",
                            style: const TextStyle(color: WatchColors.text, fontSize: 13.0),
                          )
                        else ...[
                          Text(
                            song?.title ?? l10n.watchNothingPlaying,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: WatchColors.text,
                              fontSize: 15.0,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (song != null && song.artist.isNotEmpty)
                            Text(
                              song.artist,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: WatchColors.secondary, fontSize: 12.0),
                            ),
                        ],
                        const SizedBox(height: 8.0),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            WatchRoundButton(
                              icon: TablerIcons.player_skip_back,
                              onPressed: () => _command(_watch.previous),
                            ),
                            WatchRoundButton(
                              icon: (status?.isPlaying ?? false) ? TablerIcons.player_pause : TablerIcons.player_play,
                              size: 56.0,
                              filled: true,
                              onPressed: () => _command(_watch.playPause),
                            ),
                            WatchRoundButton(
                              icon: TablerIcons.player_skip_forward,
                              onPressed: () => _command(_watch.next),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8.0),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            WatchRoundButton(
                              icon: TablerIcons.list,
                              size: 36.0,
                              tooltip: l10n.watchQueue,
                              onPressed: () => pushWatchPage<void>(context, const WatchQueuePage()),
                            ),
                            WatchRoundButton(
                              icon: TablerIcons.volume,
                              size: 36.0,
                              tooltip: l10n.watchVolume,
                              onPressed: () => pushWatchPage<void>(context, const WatchVolumePage()),
                            ),
                            WatchRoundButton(
                              icon: TablerIcons.books,
                              size: 36.0,
                              tooltip: l10n.watchLibrary,
                              onPressed: () => pushWatchPage<void>(context, const WatchLibraryScreen()),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

String _clock(double seconds) {
  final s = seconds.isFinite ? seconds.round() : 0;
  return "${s ~/ 60}:${(s % 60).toString().padLeft(2, "0")}";
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.dragging});

  final double progress;
  final bool dragging;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = dragging ? 8.0 : 4.0;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: size.shortestSide / 2 - stroke);
    final track = Paint()
      ..color = Colors.white12
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawArc(rect, 0, 2 * math.pi, false, track);
    if (progress <= 0) return;
    final fill = Paint()
      ..color = WatchColors.accent
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;
    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * progress, false, fill);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress || old.dragging != dragging;
}

/// Big buttons for the device's volume; the crown works here too.
class WatchVolumePage extends StatefulWidget {
  const WatchVolumePage({super.key});

  @override
  State<WatchVolumePage> createState() => _WatchVolumePageState();
}

class _WatchVolumePageState extends State<WatchVolumePage> {
  double? _volume;
  Timer? _send;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _send?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _set(double volume) {
    setState(() => _volume = volume.clamp(0.0, 1.0));
    _send ??= Timer(const Duration(milliseconds: 200), () {
      _send = null;
      if (_volume case final v?) unawaited(_watch.setVolume(v));
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: WatchColors.background,
      body: WatchRotaryScroll(
        controller: _scroll,
        onTurn: (delta) => _set((_volume ?? _watch.status.value?.volume ?? 1.0) - delta / 1000),
        child: ValueListenableBuilder<ConnectStatus?>(
          valueListenable: _watch.status,
          builder: (context, status, _) {
            final volume = _volume ?? status?.volume ?? 1.0;
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.watchVolume, style: const TextStyle(color: WatchColors.accent, fontSize: 14.0)),
                  const SizedBox(height: 6.0),
                  Text(
                    "${(volume * 100).round()}%",
                    style: const TextStyle(color: WatchColors.text, fontSize: 28.0, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10.0),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      WatchRoundButton(icon: TablerIcons.minus, size: 52.0, onPressed: () => _set(volume - 0.1)),
                      const SizedBox(width: 20.0),
                      WatchRoundButton(icon: TablerIcons.plus, size: 52.0, onPressed: () => _set(volume + 0.1)),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The device's queue in play order; tap a track to jump to it.
class WatchQueuePage extends StatefulWidget {
  const WatchQueuePage({super.key});

  @override
  State<WatchQueuePage> createState() => _WatchQueuePageState();
}

class _WatchQueuePageState extends State<WatchQueuePage> {
  final _scroll = ScrollController();
  bool _scrolledToCurrent = false;

  @override
  void initState() {
    super.initState();
    unawaited(_watch.refreshQueue());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _jump(int linearIndex) async {
    final ok = await _watch.jumpTo(linearIndex);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      watchToast(context, AppLocalizations.of(context)!.watchSendFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AnimatedBuilder(
      animation: Listenable.merge([_watch.queue, _watch.status]),
      builder: (context, _) {
        final queue = _watch.queue.value;
        final current = _watch.status.value?.queueIndex ?? queue?.index;
        final order = queue?.playOrder ?? const <int>[];
        if (!_scrolledToCurrent && queue != null && current != null) {
          _scrolledToCurrent = true;
          final position = order.indexOf(current);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients && position > 0) {
              _scroll.jumpTo((position * 58.0).clamp(0, _scroll.position.maxScrollExtent));
            }
          });
        }
        return WatchListPage(
          title: l10n.watchQueue,
          controller: _scroll,
          children: [
            if (queue == null)
              const Center(child: SizedBox.square(dimension: 22.0, child: CircularProgressIndicator(strokeWidth: 2.0)))
            else if (queue.isEmpty)
              WatchMessage(l10n.watchQueueEmpty)
            else
              for (final i in order)
                Builder(
                  builder: (context) {
                    final d = queue.describe(i);
                    return WatchTile(
                      title: d.title,
                      subtitle: d.artist,
                      selected: i == current,
                      icon: i == current ? TablerIcons.player_play : null,
                      onTap: () => _jump(i),
                    );
                  },
                ),
          ],
        );
      },
    );
  }
}

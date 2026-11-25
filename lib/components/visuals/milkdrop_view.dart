import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/music_player_background_task.dart';
import 'package:diapason/services/visual_audio_levels.dart';
import 'package:diapason/utils/device_form_factor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// The patterns the animated visual can draw, in the order the shader numbers them.
enum MilkdropPreset { plasma, kaleidoscope, tunnel, nebula, vortex }

extension MilkdropPresetLabel on MilkdropPreset {
  String label(AppLocalizations l10n) => switch (this) {
    MilkdropPreset.plasma => l10n.visualPresetPlasma,
    MilkdropPreset.kaleidoscope => l10n.visualPresetKaleidoscope,
    MilkdropPreset.tunnel => l10n.visualPresetTunnel,
    MilkdropPreset.nebula => l10n.visualPresetNebula,
    MilkdropPreset.vortex => l10n.visualPresetVortex,
  };
}

/// Fine-tuning of one preset: how fast it moves, how bright its pattern is, how long trails linger, how much it warps.
class MilkdropTune {
  const MilkdropTune({this.speed = 1, this.intensity = 1, this.trail = 0.9, this.warp = 1});

  final double speed;
  final double intensity;
  final double trail;
  final double warp;

  static const defaults = MilkdropTune();

  MilkdropTune copyWith({double? speed, double? intensity, double? trail, double? warp}) => MilkdropTune(
    speed: speed ?? this.speed,
    intensity: intensity ?? this.intensity,
    trail: trail ?? this.trail,
    warp: warp ?? this.warp,
  );

  Map<String, double> toJson() => {"speed": speed, "intensity": intensity, "trail": trail, "warp": warp};

  factory MilkdropTune.fromJson(Map<String, dynamic> json) {
    double read(String key, double fallback, double min, double max) =>
        ((json[key] as num?)?.toDouble() ?? fallback).clamp(min, max);
    return MilkdropTune(
      speed: read("speed", 1, 0.1, 3),
      intensity: read("intensity", 1, 0.2, 2.5),
      trail: read("trail", 0.9, 0.5, 0.98),
      warp: read("warp", 1, 0, 3),
    );
  }

  /// The tuning of [preset] stored in [raw] (the settings' JSON), defaults when absent or unreadable.
  static MilkdropTune of(String raw, MilkdropPreset preset) {
    if (raw.isEmpty) return defaults;
    try {
      final all = jsonDecode(raw) as Map<String, dynamic>;
      final entry = all[preset.name];
      return entry is Map<String, dynamic> ? MilkdropTune.fromJson(entry) : defaults;
    } catch (_) {
      return defaults;
    }
  }

  /// [raw] with [preset]'s entry replaced by [tune] (removed when it equals the defaults).
  static String update(String raw, MilkdropPreset preset, MilkdropTune tune) {
    Map<String, dynamic> all;
    try {
      all = raw.isEmpty ? {} : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      all = {};
    }
    if (tune.toJson().toString() == defaults.toJson().toString()) {
      all.remove(preset.name);
    } else {
      all[preset.name] = tune.toJson();
    }
    return all.isEmpty ? "" : jsonEncode(all);
  }
}

/// Loads `shaders/milkdrop.frag` once.
class MilkdropShader {
  static final _log = Logger("MilkdropShader");
  static Future<ui.FragmentProgram?>? _program;

  /// TVs are left out: no one asked for it there, and the Apple TV build can't be debugged on device.
  static bool get platformSupported => !DeviceFormFactorDetector.current.isTv;

  static Future<ui.FragmentProgram?> load() {
    if (!platformSupported) return Future.value(null);
    return _program ??= ui.FragmentProgram.fromAsset("shaders/milkdrop.frag").then<ui.FragmentProgram?>(
      (program) => program,
      onError: (Object e) {
        _log.warning("Could not load the animated visual's shader: $e");
        return null;
      },
    );
  }

  /// The preset showing at [elapsed] when [setting] is -1 (cycling), else the chosen one.
  static MilkdropPreset presetFor(int setting, Duration elapsed, {Duration every = const Duration(seconds: 30)}) {
    const all = MilkdropPreset.values;
    if (setting >= 0) return all[setting % all.length];
    return all[(elapsed.inMilliseconds ~/ every.inMilliseconds) % all.length];
  }
}

/// A MilkDrop-like animation that follows the music: a fragment shader warps and fades its previous frame and adds a
/// preset's pattern on top, pushed by the bass, mids and treble.
///
/// Rendered offscreen at a reduced resolution and scaled up. It only runs while visible, while the app is in front
/// (tickers stop with it) and while something plays; the frame rate follows the visualizer's and is capped lower in
/// low-power mode.
class MilkdropView extends ConsumerStatefulWidget {
  const MilkdropView({super.key, this.showStatus = false, this.borderRadius, this.currentPreset});

  /// Show a note when the shader can't load or no audio data is coming in.
  final bool showStatus;
  final BorderRadius? borderRadius;

  /// Updated with the preset on screen (which changes by itself while cycling).
  final ValueNotifier<MilkdropPreset>? currentPreset;

  @override
  ConsumerState<MilkdropView> createState() => _MilkdropViewState();
}

class _MilkdropViewState extends ConsumerState<MilkdropView> with SingleTickerProviderStateMixin {
  static final _log = Logger("MilkdropView");

  late final Ticker _ticker = createTicker(_onTick);
  final _levels = VisualAudioLevels();
  final _repaint = ValueNotifier<int>(0);
  final _frame = _MilkdropFrame();

  ui.FragmentShader? _shader;
  bool _failed = false;
  bool _visible = true;
  bool _playing = false;
  StreamSubscription<PlaybackState>? _playback;

  Size _size = Size.zero;
  Duration _lastTick = Duration.zero;
  Duration _lastDrawn = Duration.zero;
  double _time = 0;
  final _clock = Stopwatch()..start();
  bool _hasFeedback = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadShader());
    _levels.start(fps: _fps);
    if (GetIt.instance.isRegistered<MusicPlayerBackgroundTask>()) {
      final handler = GetIt.instance<MusicPlayerBackgroundTask>();
      _playing = handler.playbackState.valueOrNull?.playing ?? false;
      _playback = handler.playbackState.listen((state) {
        if (state.playing == _playing) return;
        _playing = state.playing;
        _updateTicker();
      });
    }
  }

  Future<void> _loadShader() async {
    final program = await MilkdropShader.load();
    if (!mounted) return;
    if (program == null) {
      setState(() => _failed = true);
      return;
    }
    try {
      _shader = program.fragmentShader();
    } catch (e) {
      _log.warning("Could not create the animated visual's shader: $e");
      setState(() => _failed = true);
      return;
    }
    // Draw one frame even when paused, so the view isn't blank.
    _draw(0);
    _updateTicker();
  }

  @override
  void dispose() {
    _ticker.dispose();
    unawaited(_playback?.cancel());
    _levels.dispose();
    _frame.image?.dispose();
    _frame.image = null;
    _shader?.dispose();
    _repaint.dispose();
    super.dispose();
  }

  bool get _lowPower => FinampSettingsHelper.finampSettings.milkdropLowPower;

  int get _fps {
    final fps = FinampSettingsHelper.finampSettings.visualizerFps.clamp(15, 60);
    return _lowPower ? min(fps, 20) : fps;
  }

  void _updateTicker() {
    if (!mounted) return;
    final run = _shader != null && _visible && _playing;
    if (run && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _lastDrawn = Duration.zero;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (elapsed - _lastDrawn < Duration(microseconds: 1000000 ~/ _fps)) return;
    final dt = _lastTick == Duration.zero ? 1 / _fps : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    _lastDrawn = elapsed;
    _draw(dt.clamp(0.0, 0.2));
  }

  /// Renders the next frame offscreen; the previous one is the shader's feedback input.
  void _draw(double dt) {
    final shader = _shader;
    if (shader == null || _size.isEmpty) return;
    _levels.update(dt);
    final preset = MilkdropShader.presetFor(FinampSettingsHelper.finampSettings.milkdropPreset, _clock.elapsed);
    final tune = MilkdropTune.of(FinampSettingsHelper.finampSettings.milkdropTuning, preset);
    // Time runs faster with the music's energy, like MilkDrop's.
    _time += dt * (0.6 + _levels.bass * 0.8 + _levels.beat * 0.6) * tune.speed;

    final scale = _lowPower ? 0.35 : 0.6;
    final cap = _lowPower ? 360.0 : 720.0;
    final longest = max(_size.width, _size.height) * scale;
    final factor = longest > cap ? cap / longest * scale : scale;
    final width = max(16, (_size.width * factor).round());
    final height = max(16, (_size.height * factor).round());

    final previous = _frame.image;
    final feedback = _hasFeedback && previous != null && previous.width == width && previous.height == height;
    final tint = Theme.of(context).colorScheme.primary;
    widget.currentPreset?.value = preset;

    var i = 0;
    shader
      ..setFloat(i++, width.toDouble())
      ..setFloat(i++, height.toDouble())
      ..setFloat(i++, _time)
      ..setFloat(i++, _levels.bass)
      ..setFloat(i++, _levels.mid)
      ..setFloat(i++, _levels.treble)
      ..setFloat(i++, _levels.beat)
      ..setFloat(i++, preset.index.toDouble())
      ..setFloat(i++, feedback ? 1 : 0)
      ..setFloat(i++, tint.r)
      ..setFloat(i++, tint.g)
      ..setFloat(i++, tint.b)
      ..setFloat(i++, tune.speed)
      ..setFloat(i++, tune.intensity)
      ..setFloat(i++, tune.trail)
      ..setFloat(i++, tune.warp)
      ..setImageSampler(0, feedback ? previous : _frame.blank);

    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..shader = shader);
    final picture = recorder.endRecording();
    final next = picture.toImageSync(width, height);
    picture.dispose();

    _frame.image = next;
    previous?.dispose();
    _hasFeedback = true;
    _repaint.value++;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(finampSettingsProvider.milkdropLowPower, (_, _) => _hasFeedback = false);
    final l10n = AppLocalizations.of(context)!;
    if (_failed) {
      return widget.showStatus ? _Note(text: l10n.visualAnimatedUnavailable) : const SizedBox.shrink();
    }
    return VisibilityDetector(
      key: ObjectKey(this),
      onVisibilityChanged: (info) {
        final visible = info.visibleFraction > 0;
        if (visible == _visible) return;
        _visible = visible;
        _updateTicker();
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          if (size != _size) {
            _size = size;
            _hasFeedback = false;
            if (_shader != null && !_ticker.isActive) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && !_ticker.isActive) _draw(0);
              });
            }
          }
          Widget view = RepaintBoundary(
            child: CustomPaint(
              size: size,
              painter: _MilkdropPainter(frame: _frame, repaint: _repaint),
            ),
          );
          if (widget.borderRadius != null) view = ClipRRect(borderRadius: widget.borderRadius!, child: view);
          if (!widget.showStatus) return view;
          return Stack(
            fit: StackFit.expand,
            children: [
              view,
              ValueListenableBuilder<bool>(
                valueListenable: _levels.receiving,
                builder: (context, receiving, _) => receiving
                    ? const SizedBox.shrink()
                    : Align(
                        alignment: Alignment.bottomCenter,
                        child: _Note(text: l10n.visualAnimatedNoAudio),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MilkdropFrame {
  ui.Image? image;

  /// Bound when there is no previous frame yet: the sampler must always hold an image.
  late final ui.Image blank = () {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 1, 1), Paint()..color = Colors.black);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(1, 1);
    picture.dispose();
    return image;
  }();
}

class _MilkdropPainter extends CustomPainter {
  _MilkdropPainter({required this.frame, required Listenable repaint}) : super(repaint: repaint);

  final _MilkdropFrame frame;

  @override
  void paint(Canvas canvas, Size size) {
    final image = frame.image;
    if (image == null) {
      canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
      return;
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_MilkdropPainter oldDelegate) => oldDelegate.frame != frame;
}

class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(8)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      ),
    );
  }
}

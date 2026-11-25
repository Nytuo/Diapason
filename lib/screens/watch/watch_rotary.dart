import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// A watch's crown or rotating bezel, as forwarded by MainActivity: how many pixels to scroll by, positive towards
/// the end of a list.
class WatchRotary {
  WatchRotary._();

  static const _channel = MethodChannel("fr.nytuo.diapason/rotary");
  static final _scrolls = StreamController<double>.broadcast();
  static bool _listening = false;

  static Stream<double> get scrolls {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == "scroll" && call.arguments is num) _scrolls.add((call.arguments as num).toDouble());
      });
    }
    return _scrolls.stream;
  }
}

/// Scrolls [controller] with the crown while it is on screen (the top route's list takes the turns).
class WatchRotaryScroll extends StatefulWidget {
  const WatchRotaryScroll({super.key, required this.controller, required this.child, this.onTurn});

  final ScrollController controller;
  final Widget child;

  /// Called instead of scrolling when set (e.g. the crown sets the volume on the now playing page).
  final void Function(double delta)? onTurn;

  @override
  State<WatchRotaryScroll> createState() => _WatchRotaryScrollState();
}

class _WatchRotaryScrollState extends State<WatchRotaryScroll> {
  StreamSubscription<double>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = WatchRotary.scrolls.listen(_onScroll);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onScroll(double delta) {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    if (widget.onTurn case final onTurn?) return onTurn(delta);
    final c = widget.controller;
    if (!c.hasClients) return;
    final target = (c.offset + delta).clamp(c.position.minScrollExtent, c.position.maxScrollExtent);
    c.animateTo(target, duration: const Duration(milliseconds: 80), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

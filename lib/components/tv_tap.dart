import 'package:diapason/utils/device_form_factor.dart';
import 'package:flutter/material.dart';

/// Makes a gesture-only area reachable with a TV remote: on a TV it can take focus and the select button triggers
/// [onTap]; everywhere else it is just [child].
class TvTap extends StatelessWidget {
  const TvTap({super.key, required this.onTap, required this.child, this.focusNode});

  final VoidCallback onTap;
  final FocusNode? focusNode;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!DeviceFormFactorDetector.current.isTv) return child;
    return FocusableActionDetector(
      focusNode: focusNode,
      actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => onTap())},
      child: child,
    );
  }
}

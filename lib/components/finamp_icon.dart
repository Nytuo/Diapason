import 'package:diapason/color_schemes.g.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/widget_bindings_observer_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class FinampIcon extends ConsumerWidget {
  final double height;
  final double width;
  final Color? overrideColor;
  const FinampIcon(this.width, this.height, {this.overrideColor, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final useMonochromeIcon = ref.watch(finampSettingsProvider.useMonochromeIcon);
    if (!useMonochromeIcon && overrideColor == null) {
      return Image.asset("images/diapason_cropped.png", width: width, height: height);
    }

    final color = overrideColor ?? Theme.of(context).colorScheme.primary;

    return ColorFiltered(
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      child: Image.asset("images/diapason_glyph.png", width: width, height: height),
    );
  }
}

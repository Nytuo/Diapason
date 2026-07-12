import 'package:diapason/screens/tv/tv_home_screen.dart';
import 'package:diapason/screens/watch/watch_screen.dart';
import 'package:diapason/utils/device_form_factor.dart';
import 'package:diapason/services/backends/backend_registry.dart';
import 'package:diapason/screens/ipod/ipod_controller.dart';
import 'package:diapason/screens/ipod/ipod_shell.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:diapason/services/finamp_user_helper.dart';
import 'package:diapason/screens/login_screen.dart';
import 'package:diapason/screens/music_screen.dart';
import 'package:diapason/screens/view_selector.dart';

class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  static const routeName = "/";

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final finampUserHelper = GetIt.instance<FinampUserHelper>();
    final user = finampUserHelper.currentUser;

    if (InterfaceMode.fromName(ref.watch(finampSettingsProvider.interfaceMode)) == InterfaceMode.ipod) {
      return const IpodShell();
    }

    if (DeviceFormFactorDetector.current.isWatch) return const WatchScreen();

    if (user == null) {
      final hasOtherSources = GetIt.instance<BackendRegistry>().configured.isNotEmpty;
      if (!hasOtherSources) return const LoginScreen();
      return DeviceFormFactorDetector.current.isTv ? const TvHomeScreen() : const MusicScreen();
    } else if (user.currentView == null) {
      return const ViewSelector();
    } else if (DeviceFormFactorDetector.current.isTv) {
      return const TvHomeScreen();
    } else {
      return const MusicScreen();
    }
  }
}

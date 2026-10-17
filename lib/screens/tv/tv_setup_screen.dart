import 'package:diapason/screens/login_screen.dart';
import 'package:diapason/screens/tv/tv_landing.dart';
import 'package:diapason/screens/tv/tv_source_offer.dart';
import 'package:diapason/screens/tv/tv_widgets.dart';
import 'package:diapason/utils/tv_zoom.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// First launch of a TV that has no accounts. Typing a server address and a password with a remote is miserable, so
/// the phone does it: this screen waits for accounts sent from Diapason Connect, with typing as the way out.
class TvSetupScreen extends StatelessWidget {
  const TvSetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return TvSourceOfferListener(
      onImported: () {
        if (!context.mounted) return;
        Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const TvLanding()));
      },
      child: TvNative(
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Padding(
                  padding: const EdgeInsets.all(48.0),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(TablerIcons.device_mobile, size: 96.0, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(height: 24.0),
                        Text(
                          "Set up from your phone",
                          style: Theme.of(context).textTheme.displaySmall?.copyWith(color: Colors.white),
                        ),
                        const SizedBox(height: 24.0),
                        const Text(
                          "1. Open Diapason on your phone, on the same Wi-Fi as this TV.\n"
                          "2. Go to Connect and tap the person icon next to this TV.\n"
                          "3. Choose the accounts to send, then accept them here.",
                          style: TextStyle(color: Colors.white70, fontSize: 24.0, height: 1.6),
                        ),
                        const SizedBox(height: 40.0),
                        TvFocusable(
                          autofocus: true,
                          onPressed: () =>
                              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const LoginScreen())),
                          builder: (context, focused) => AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 16.0),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12.0),
                              color: focused
                                  ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.35)
                                  : Colors.white10,
                              border: Border.all(
                                color: focused ? Theme.of(context).colorScheme.primary : Colors.transparent,
                                width: 3.0,
                              ),
                            ),
                            child: const Text(
                              "Enter the details here instead",
                              style: TextStyle(color: Colors.white, fontSize: 22.0),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

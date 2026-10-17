import 'package:diapason/screens/music_screen.dart';
import 'package:diapason/screens/tv/tv_profile_picker_screen.dart';
import 'package:diapason/screens/tv/tv_source_offer.dart';
import 'package:diapason/services/tv/tv_profile_service.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

/// Where the TV starts. With several people sharing it, ask who is listening; with one, go straight in.
class TvLanding extends StatefulWidget {
  const TvLanding({super.key});

  @override
  State<TvLanding> createState() => _TvLandingState();
}

class _TvLandingState extends State<TvLanding> {
  late final Future<void> _ready = _prepare();

  TvProfileService get _service => GetIt.instance<TvProfileService>();

  Future<void> _prepare() async {
    // A first account added on a fresh TV has no profile yet; give it one.
    await _service.adoptExistingSources();
    final profiles = _service.profiles;
    if (profiles.length == 1 && _service.active?.id != profiles.first.id) await _service.select(profiles.first.id);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            backgroundColor: Colors.black,
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return TvSourceOfferListener(
          onImported: () {
            if (mounted) setState(() {});
          },
          child: _service.profiles.length > 1 ? const TvProfilePickerScreen() : const MusicScreen(),
        );
      },
    );
  }
}

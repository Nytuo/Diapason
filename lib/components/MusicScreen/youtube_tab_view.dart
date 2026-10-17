import 'package:diapason/components/MusicScreen/youtube_results.dart';
import 'package:diapason/components/YtDlp/youtube_setup_view.dart';
import 'package:diapason/services/youtube/youtube_availability.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

class YouTubeTabView extends ConsumerStatefulWidget {
  const YouTubeTabView({super.key});

  @override
  ConsumerState<YouTubeTabView> createState() => _YouTubeTabViewState();
}

class _YouTubeTabViewState extends ConsumerState<YouTubeTabView> {
  final _query = TextEditingController();
  String _active = "";

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _search() => setState(() => _active = _query.text.trim());

  void _clear() {
    _query.clear();
    setState(() => _active = "");
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(youTubeAvailableProvider)) return const YouTubeSetupView();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12.0),
          child: TextField(
            controller: _query,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            onChanged: (value) {
              if (value.isEmpty && _active.isNotEmpty) _clear();
            },
            decoration: InputDecoration(
              hintText: "Search YouTube or paste a link",
              prefixIcon: const Icon(TablerIcons.search),
              suffixIcon: IconButton(icon: const Icon(TablerIcons.arrow_right), onPressed: _search),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: _active.isEmpty ? const YouTubeHome() : YouTubeSearchResults(query: _active, debounce: Duration.zero),
        ),
      ],
    );
  }
}

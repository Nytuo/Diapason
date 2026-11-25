import 'package:diapason/components/GenreScreen/genre_screen_content.dart';
import 'package:diapason/models/jellyfin_models.dart';
import 'package:diapason/screens/desktop/desktop_page_frame.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/finamp_user_helper.dart';
import 'package:diapason/services/genre_screen_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';

/// A genre in the desktop content area: the genre screen's content in the
/// desktop page frame, without the mobile now-playing bar.
class DesktopGenreDetail extends ConsumerStatefulWidget {
  const DesktopGenreDetail({super.key, required this.genre});

  final BaseItemDto genre;

  @override
  ConsumerState<DesktopGenreDetail> createState() => _DesktopGenreDetailState();
}

class _DesktopGenreDetailState extends ConsumerState<DesktopGenreDetail> {
  Key _contentKey = UniqueKey();

  Future<void> _refresh() async {
    ref.invalidate(genreCuratedItemsProvider);
    setState(() => _contentKey = UniqueKey());
  }

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    final library = GetIt.instance.isRegistered<FinampUserHelper>()
        ? GetIt.instance<FinampUserHelper>().currentUser?.currentView
        : null;
    return DesktopPageFrame(
      child: Material(
        color: p.bg,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: GenreScreenContent(key: _contentKey, parent: widget.genre, library: library),
        ),
      ),
    );
  }
}

import 'package:diapason/components/MusicScreen/music_screen_tab_view.dart';
import 'package:diapason/components/MusicScreen/sort_and_filter_row.dart';
import 'package:diapason/l10n/app_localizations.dart';
import 'package:diapason/models/finamp_models.dart';
import 'package:diapason/models/music_models.dart';
import 'package:diapason/screens/desktop/desktop_page_frame.dart';
import 'package:diapason/screens/desktop/desktop_router.dart';
import 'package:diapason/screens/desktop/desktop_theme.dart';
import 'package:diapason/services/music_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A home-screen section or a "show all" list (genre, collection, ...) shown
/// in the desktop content area at desktop density, instead of the mobile
/// single-tab `MusicScreen`.
class DesktopSectionPage extends ConsumerStatefulWidget {
  const DesktopSectionPage({super.key, required this.route});

  final DesktopSectionRoute route;

  @override
  ConsumerState<DesktopSectionPage> createState() => _DesktopSectionPageState();
}

class _DesktopSectionPageState extends ConsumerState<DesktopSectionPage> {
  late final SortAndFilterController _controller = SortAndFilterController(
    startingConfig: widget.route.config.sortConfig,
    contentType: _contentType,
  );

  ContentType get _contentType => switch (widget.route.config.base) {
    QueuesHomeSection() => ContentType.home,
    TabsHomeSection tabSection => tabSection.contentType,
    CollectionHomeSection() => ContentType.mixed,
  };

  @override
  Widget build(BuildContext context) {
    final p = DesktopThemeScope.of(context);
    final config = widget.route.config;
    FinampDisplayable? displayable = ref.watch(resolveSectionProvider(config)).value;
    if (displayable is FinampSortable) {
      displayable = displayable.copyWith(ref.watch(resolveSortProvider(_controller)));
    }
    return Material(
      color: p.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DesktopPageHeader(title: config.getTitle(AppLocalizations.of(context)!)),
          if (displayable is FinampSortable)
            SortAndFilterRow(tabType: _contentType, controller: _controller, allowFilters: widget.route.allowFilters),
          Expanded(
            child: displayable == null
                ? const Center(child: CircularProgressIndicator.adaptive())
                : Material(
                    type: MaterialType.transparency,
                    child: MusicScreenTabView(displayable: displayable, allowTrackGestures: true),
                  ),
          ),
        ],
      ),
    );
  }
}

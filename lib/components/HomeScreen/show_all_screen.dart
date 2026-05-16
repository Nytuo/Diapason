/*import 'dart:async';

import 'package:finamp/components/MusicScreen/music_screen_tab_view.dart' show MusicRefreshCallback;
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/music_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import '../../l10n/app_localizations.dart';
import '../../services/finamp_settings_helper.dart';
import '../../services/item_by_id_provider.dart';
import '../../services/music_screen_provider.dart';
import '../AlbumScreen/track_list_tile.dart';
import '../Buttons/cta_medium.dart';
import '../MusicScreen/item_wrapper.dart';
import '../finamp_app_bar_back_button.dart';
import '../first_page_progress_indicator.dart';
import '../new_page_progress_indicator.dart';
import '../now_playing_bar.dart';

// TODO this is essentially used as a collection screen at the moment.  Rename?
class ShowAllScreen extends ConsumerStatefulWidget {
  const ShowAllScreen({super.key, this.refresh});

  final MusicRefreshCallback? refresh;

  static const routeName = "/show-all";

  @override
  ConsumerState<ShowAllScreen> createState() => _ShowAllScreenState();
}

class _ShowAllScreenState extends ConsumerState<ShowAllScreen> {
  Future<List<BaseItemDto>>? offlineSortedItems;

  late AutoScrollController controller;
  Timer? timer;

  //late HomeScreenSectionConfiguration sectionInfo;

  @override
  void initState() {
    controller = AutoScrollController(
      suggestedRowHeight: 72,
      viewportBoundaryGetter: () => Rect.fromLTRB(0, 0, 0, MediaQuery.of(context).padding.bottom),
      axis: Axis.vertical,
    );
    super.initState();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (!context.mounted) return;
    ref.read(pageControl.notifier).refresh();
  }

  FinampDisplayable? _sectionInfoCache;
  FinampDisplayable get sectionInfo =>
      _sectionInfoCache ?? ModalRoute.of(context)!.settings.arguments as FinampDisplayable;

  PagedContentProvider get pageControl {
    return pagedContentProvider(sectionInfo);
  }

  @override
  Widget build(BuildContext context) {
    widget.refresh?.callback = _refresh;

    final emptyListIndicator = Padding(
      padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 32.0),
      child: Column(
        children: [
          Text(
            AppLocalizations.of(context)!.emptyFilteredListTitle,
            style: TextStyle(fontSize: 24),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            AppLocalizations.of(context)!.emptyFilteredListSubtitle,
            style: TextStyle(fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          CTAMedium(
            icon: TablerIcons.filter_x,
            text: AppLocalizations.of(context)!.resetFiltersButton,
            onPressed: () {
              FinampSetters.setOnlyShowFavorites(DefaultSettings.onlyShowFavorites);
              FinampSetters.setOnlyShowFullyDownloaded(DefaultSettings.onlyShowFullyDownloaded);
            },
          ),
        ],
      ),
    );

    var content = PagedListView<int, FinampPlayable>.separated(
      state: ref.watch(pageControl),
      fetchNextPage: () {
        ref.read(pageControl.notifier).newPage();
      },
      scrollController: controller,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      builderDelegate: PagedChildBuilderDelegate<FinampPlayable>(
        itemBuilder: (context, item, index) {
          return AutoScrollTag(
            key: ValueKey(index),
            controller: controller,
            index: index,
            child: switch(item){
              Track() => TrackListTile(
                key: ValueKey(item.item.id),
                item: item.item,
                index: index,
                // when the tabBar was filtered and we only have the tracks tab,
                // we can allow Dismiss gestures in the track list
                parentItem: item.source.item,
                source: item.source,
                fetchChildren: () {
                  return ref.read(pageControl.notifier).loadSlice(index);
                },
              ),
            FinampPlayableItem() => ItemWrapper(item: item.item, source: item.source, isGrid: false),
            _ => throw UnsupportedError("Unsupported playable item $item"),
            }
          );
        },
        firstPageProgressIndicatorBuilder: (_) => const FirstPageProgressIndicator(),
        newPageProgressIndicatorBuilder: (_) => const NewPageProgressIndicator(),
        noItemsFoundIndicatorBuilder: (_) => emptyListIndicator,
      ),
      separatorBuilder: (context, index) => const SizedBox.shrink(),
    );

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        systemOverlayStyle: SystemUiOverlayStyle(
          // this is needed to ensure the player screen stays in full screen mode WITHOUT having contrast issues in the status bar
          systemNavigationBarColor: Colors.transparent,
          systemStatusBarContrastEnforced: false,
          statusBarIconBrightness: Theme.brightnessOf(context) == Brightness.dark ? Brightness.light : Brightness.dark,
        ),
        elevation: 0,
        scrolledUnderElevation: 0.0, // disable tint/shadow when content is scrolled under the app bar
        centerTitle: true,
        toolbarHeight: 53,
        title: Text(sectionInfo.),
        leading: FinampAppBarBackButton(),
        actions: [],
      ),
      body: RefreshIndicator(onRefresh: () async => _refresh(), child: content),
      bottomNavigationBar: const NowPlayingBar(),
    );
  }
}
*/

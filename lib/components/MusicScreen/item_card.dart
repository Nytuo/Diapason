import 'package:finamp/components/album_image.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/generate_subtitle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';

const double _itemCollectionCardCoverSize = 110;
const double _itemCollectionCardSpacing = 6;

/// Card content for items. You probably shouldn't use this widget directly,
/// use ItemWrapper instead.
class ItemCard extends ConsumerWidget {
  const ItemCard({super.key, required this.item, this.parentType, this.onTap});

  final BaseItemDto item;
  final TabContentType? parentType;
  final void Function()? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      constraints: const BoxConstraints(maxWidth: _itemCollectionCardCoverSize),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: AlbumImage.defaultBorderRadius),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 1, // Square aspect ratio for album art
            child: Card(
              margin: EdgeInsets.zero,
              child: ClipRRect(
                borderRadius: AlbumImage.defaultBorderRadius,
                child: Stack(
                  children: [
                    AlbumImage(item: item),
                    Positioned.fill(
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(onTap: onTap),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (ref.watch(finampSettingsProvider.showTextOnGridView)) ...[
            const SizedBox(height: _itemCollectionCardSpacing, width: 1),
            _ItemCollectionCardText(item: item, parentType: parentType),
          ],
        ],
      ),
    );
  }
}

class _ItemCollectionCardText extends ConsumerWidget {
  const _ItemCollectionCardText({required this.item, required this.parentType});

  final BaseItemDto item;
  final TabContentType? parentType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtitle = generateSubtitle(
      context: context,
      item: item,
      parentType: parentType,
      artistType: ref.watch(finampSettingsProvider.defaultArtistType),
    );

    return SizedBox(
      height: calculateTextHeight(
        style: TextTheme.of(context).bodySmall!,
        lines: calculateItemCollectionTextLines(BaseItemDtoType.fromItem(item)),
      ),
      child: Align(
        alignment: Alignment.topLeft,
        child: Wrap(
          // Runs must be horizontal to constrain child width.  Use large
          // spacing to force subtitle to wrap to next run
          spacing: 1000,
          children: [
            Text(
              item.name ?? "Unknown Name",
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
              style: Theme.of(context).textTheme.bodySmall!.copyWith(fontWeight: FontWeight.w600),
            ),
            if (subtitle != null)
              Text(
                subtitle,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}

/// This might calculate the width base on the device width in the future, or something similar
double calculateItemCollectionCardWidth(BuildContext context, BaseItemDtoType itemType) {
  return _itemCollectionCardCoverSize;
}

int calculateItemCollectionTextLines(BaseItemDtoType itemType) {
  switch (itemType) {
    case BaseItemDtoType.artist:
    case BaseItemDtoType.track:
      return 2;
    case BaseItemDtoType.album:
    case BaseItemDtoType.playlist:
    case BaseItemDtoType.genre:
    case _:
      return 3;
  }
}

double calculateItemCollectionCardHeight(BuildContext context, BaseItemDtoType itemType) {
  return _itemCollectionCardCoverSize +
      (GetIt.instance<ProviderContainer>().read(finampSettingsProvider.showTextOnGridView)
          ? _itemCollectionCardSpacing
          : 0) +
      calculateTextHeight(style: TextTheme.of(context).bodySmall!, lines: calculateItemCollectionTextLines(itemType));
}

double calculateTextHeight({required TextStyle style, required int lines}) {
  return (GetIt.instance<ProviderContainer>().read(finampSettingsProvider.showTextOnGridView)
      ? (style.height ?? 1.0) * (style.fontSize ?? 16) * lines
      : 0);
}

import 'package:finamp/components/album_image.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Card content for AlbumItem. You probably shouldn't use this widget directly,
/// use AlbumItem instead.
class ArtistItemCard extends ConsumerWidget {
  const ArtistItemCard({super.key, required this.item, this.onTap});

  final BaseItemDto item;
  final void Function()? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Stack(
          children: [
            AlbumImage(item: item, borderRadius: BorderRadius.circular(9999)),
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(onTap: onTap),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ref.watch(finampSettingsProvider.showTextOnGridView)
            ? _ArtistItemCardText(item: item)
            : const SizedBox.shrink(),
      ],
    );
  }
}

class _ArtistItemCardText extends StatelessWidget {
  const _ArtistItemCardText({required this.item});

  final BaseItemDto item;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Text(
        item.name ?? "Unknown Name",
        overflow: TextOverflow.ellipsis,
        maxLines: 2,
        style: Theme.of(context).textTheme.bodySmall!.copyWith(fontWeight: FontWeight.w500),
      ),
    );
  }
}

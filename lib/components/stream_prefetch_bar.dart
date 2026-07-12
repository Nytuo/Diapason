import 'package:diapason/services/stream_cache_service.dart';
import 'package:file_sizes/file_sizes.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

class StreamPrefetchBar extends StatelessWidget {
  const StreamPrefetchBar({super.key});

  @override
  Widget build(BuildContext context) {
    final cache = GetIt.instance<StreamCacheService>();

    return ValueListenableBuilder<StreamPrefetch?>(
      valueListenable: cache.prefetch,
      builder: (context, prefetch, _) {
        if (prefetch == null) return const SizedBox.shrink();

        final theme = Theme.of(context);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      prefetch.title == null ? "Caching…" : "Caching ${prefetch.title}…",
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8.0),
                  Text(
                    "${(prefetch.fraction * 100).round()}%",
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 4.0),
              ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(2.0)),
                child: LinearProgressIndicator(value: prefetch.fraction, minHeight: 3.0),
              ),
            ],
          ),
        );
      },
    );
  }
}

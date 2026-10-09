part of '../view/search_screen.dart';

class _SearchResultRow extends StatelessWidget {
  const _SearchResultRow({
    required this.result,
    required this.transportType,
    required this.onTap,
  });

  final SearchResult result;
  final TransportType transportType;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final leadingWidget = Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Center(
        child: TransportIcon(type: transportType, size: 18),
      ),
    );

    return Pressable(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 62),
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.space20,
          vertical: AppTheme.space12,
        ),
        decoration: BoxDecoration(color: cs.surfaceContainerLow),
        child: Row(
          children: [
            leadingWidget,
            const SizedBox(width: AppTheme.space12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.name,
                    style: AppTextStyles.bodyRegular.copyWith(
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                      height: 1.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: AppTheme.space2),
                  Text(
                    result.subtitle,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: cs.onSurfaceVariant,
                      height: 1.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppTheme.space8),
            Icon(
              Icons.chevron_right_rounded,
              size: 24,
              color: cs.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

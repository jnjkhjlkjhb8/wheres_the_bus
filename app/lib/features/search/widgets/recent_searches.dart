part of '../view/search_screen.dart';

class _ZeroInputSuggestions extends StatelessWidget {
  const _ZeroInputSuggestions();

  void _remove(BuildContext context, SearchResult result, int index) {
    final bloc = context.read<SearchBloc>()..add(SearchRecentRemoved(result));
    AppSnackbar.show(
      context,
      AppI18n.of(context).searchRecentRemoved(result.name),
      action: AppI18n.of(context).commonUndo,
      // Restores at the original index. Re-adding would promote the entry to
      // the top of the list, which isn't what
      // AppI18n.of(context).commonUndo claims to do.
      onAction: () => bloc.add(SearchRecentRestored(result, index)),
    );
  }

  Future<void> _clearAll(BuildContext context) async {
    final bloc = context.read<SearchBloc>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(AppI18n.of(context).searchRecentClearTitle),
        content: Text(AppI18n.of(context).searchRecentClearBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(AppI18n.of(context).searchRecentKeep),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(AppI18n.of(context).searchRecentClear),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      bloc.add(const SearchRecentsCleared());
    }
  }

  Widget _clearButton(BuildContext context, ColorScheme cs) => Pressable(
    onTap: () => unawaited(_clearAll(context)),
    semanticLabel: AppI18n.of(context).searchRecentClearSemantics,
    child: Container(
      constraints: const BoxConstraints(
        minWidth: _minTouchTarget,
        // 44 not 48: this is what sets the header band's height. Still at the
        // HIG minimum.
        minHeight: 44,
      ),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.space8),
      child: Text(
        AppI18n.of(context).commonClear,
        style: AppTextStyles.bodySmall.copyWith(
          fontWeight: FontWeight.w600,
          color: cs.onSurfaceVariant,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = AppI18n.of(context);
    final recentItems = context.select<SearchBloc, List<SearchResult>>(
      (bloc) => bloc.state.recentResults,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          label: i18n.searchRecent,
          trailing: recentItems.isEmpty ? null : _clearButton(context, cs),
        ),
        Expanded(
          child: recentItems.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppTheme.space32,
                    ),
                    child: Text(
                      i18n.searchRecentEmpty,
                      textAlign: TextAlign.center,
                      style: AppTextStyles.bodyRegular.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.zero,
                  itemCount: recentItems.length,
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    thickness: 0.5,
                    color: cs.outlineVariant,
                  ),
                  itemBuilder: (context, index) {
                    final result = recentItems[index];
                    return Dismissible(
                      key: ValueKey('recent-${result.type.name}-${result.uid}'),
                      direction: DismissDirection.endToStart,
                      onDismissed: (_) => _remove(context, result, index),
                      background: Container(
                        color: cs.errorContainer,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppTheme.space24,
                        ),
                        child: Icon(
                          Icons.delete_rounded,
                          color: cs.onErrorContainer,
                          size: 22,
                        ),
                      ),
                      child: Semantics(
                        customSemanticsActions: {
                          CustomSemanticsAction(
                            label: i18n.searchRecentRemoveOne,
                          ): () =>
                              _remove(context, result, index),
                        },
                        child: _RecentRow(
                          result: result,
                          onTap: () => _navigateToResult(context, result),
                          onLongPress: () => _remove(context, result, index),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// One history row on the empty-query screen.
class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.result,
    required this.onTap,
    this.onLongPress,
  });

  final SearchResult result;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.space20,
          vertical: 11,
        ),
        decoration: BoxDecoration(color: cs.surfaceContainerLow),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Center(
                child: Icon(
                  Icons.access_time_rounded,
                  size: 16,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
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

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/transport_icon.dart';

@Preview(name: 'SearchResultRow — all types', group: 'Search')
Widget searchResultRowPreview() {
  return MaterialApp(
    home: Scaffold(
      body: ListView(
        children: const [
          SearchResultRow(
            result: SearchResultViewData(
              type: AppSearchResultType.busRoute,
              uid: '307',
              title: '307',
              subtitle: '板橋 — 撫遠街',
            ),
          ),
          SearchResultRow(
            result: SearchResultViewData(
              type: AppSearchResultType.busStation,
              uid: 'stop-1',
              title: '台北車站(忠孝)',
              subtitle: '忠孝西路一段',
            ),
          ),
          SearchResultRow(
            result: SearchResultViewData(
              type: AppSearchResultType.mrtStation,
              uid: 'BL12',
              title: '台北車站',
              subtitle: '板南線',
            ),
          ),
          SearchResultRow(
            result: SearchResultViewData(
              type: AppSearchResultType.bikeStation,
              uid: 'bike-1',
              title: '捷運市政府站(3號出口)',
              subtitle: '可借 12 / 可停 8',
            ),
          ),
          SearchResultRow(
            result: SearchResultViewData(
              type: AppSearchResultType.traStation,
              uid: 'tra-1',
              title: '松山車站',
              subtitle: '台鐵',
            ),
          ),
          SearchResultRow(
            result: SearchResultViewData(
              type: AppSearchResultType.place,
              uid: 'place-1',
              title: '台北101',
              subtitle: '',
            ),
          ),
        ],
      ),
    ),
  );
}

class SearchResultRow extends StatelessWidget {
  const SearchResultRow({
    required this.result,
    this.onTap,
    super.key,
  });

  final SearchResultViewData result;
  final VoidCallback? onTap;

  TransportType get _transportType => switch (result.type) {
    AppSearchResultType.busRoute => TransportType.bus,
    AppSearchResultType.busStation => TransportType.busStop,
    AppSearchResultType.bikeStation => TransportType.bike,
    AppSearchResultType.traStation ||
    AppSearchResultType.traTrain => TransportType.tra,
    AppSearchResultType.thsrStation ||
    AppSearchResultType.thsrTrain => TransportType.thsr,
    AppSearchResultType.mrtStation => TransportType.mrtBL,
    AppSearchResultType.place => TransportType.location,
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final showSubtitle =
        result.subtitle.isNotEmpty && result.type != AppSearchResultType.place;
    return Pressable(
      onTap: onTap,
      semanticLabel: result.title,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.space12,
            vertical: AppTheme.space8,
          ),
          child: Row(
            children: [
              TransportIcon(type: _transportType),
              const SizedBox(width: AppTheme.space4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      result.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.heading2,
                    ),
                    if (showSubtitle)
                      Text(
                        result.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodyRegular.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppTheme.space8),
              Icon(
                Symbols.arrow_insert_rounded,
                size: 24,
                color: cs.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

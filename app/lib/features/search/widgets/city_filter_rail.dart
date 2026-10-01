part of '../view/search_screen.dart';

class _CityFilterRail extends StatelessWidget {
  const _CityFilterRail({
    required this.options,
    required this.selected,
    required this.onToggle,
  });

  /// TDX city codes, already ordered by the bloc.
  final List<String> options;

  /// The selected code, or null when results span every option. There is no
  /// "all" chip: nothing selected already says it, and one more chip on a
  /// row this narrow costs more than it explains.
  final String? selected;

  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedSize(
      duration: reduceMotion ? Duration.zero : AppMotion.short,
      curve: AppMotion.easeOut,
      alignment: Alignment.topCenter,
      child: options.length < 2
          ? const SizedBox(width: double.infinity)
          : Semantics(
              container: true,
              label: AppI18n.of(context).searchCityFilter,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.space20,
                ),
                child: FilterChipGroup<String>(
                  options: {for (final code in options) code: cityName(code)},
                  selected: {?selected},
                  onToggle: onToggle,
                ),
              ),
            ),
    );
  }
}

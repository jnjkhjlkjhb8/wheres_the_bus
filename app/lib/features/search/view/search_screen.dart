import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/city_names.dart';
import 'package:wheres_the_bus/data/models/metro_map_models.dart';
import 'package:wheres_the_bus/data/models/near_models.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/search/bloc/search_bloc.dart';
import 'package:wheres_the_bus/features/search/bloc/search_event.dart';
import 'package:wheres_the_bus/features/search/bloc/search_state.dart';
import 'package:wheres_the_bus/features/search/genui/bloc/genui_bloc.dart';
import 'package:wheres_the_bus/features/search/genui/view/genui_ask_lane.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_snackbar.dart';
import 'package:wheres_the_bus/shared/widgets/error_state_view.dart';
import 'package:wheres_the_bus/shared/widgets/filter_chip_group.dart';
import 'package:wheres_the_bus/shared/widgets/transport_icon.dart';

part '../widgets/search_result_row.dart';
part '../widgets/recent_searches.dart';
part '../widgets/city_filter_rail.dart';

/// Platform minimum for a touch target (Android 48dp / Apple HIG 44pt).
/// Applied as the hit area; the painted control stays whatever size the
/// layout calls for.
const double _minTouchTarget = 48;

/// No stop or route name comes close to this. The cap exists so a pasted
/// wall of text can't be fired at the router on every keystroke.
const int _maxQueryLength = 50;

/// This screen as somewhere to come back to: the search location carrying the
/// query that is on screen. Results are re-run rather than frozen, which is
/// what a rider returning to a departure board wants anyway.
String _backHere(BuildContext context) {
  final query = context.read<SearchBloc>().state.query;
  return AppRoutes.searchLocation(query: query.isEmpty ? null : query);
}

void _closeSearch(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(AppRoutes.home);
  }
}

void _navigateToResult(BuildContext context, SearchResult result) {
  // Persist the selection through the recent-search repository (owned by
  // SearchBloc) so every entry point — result rows, recents, and AI — records
  // history in one place instead of writing storage directly.
  context.read<SearchBloc>().add(SearchResultSelected(result));
  switch (result.type) {
    case SearchResultType.busRoute:
      unawaited(context.push(AppRoutes.busRoute(result.uid)));
    case SearchResultType.busStation:
      context.go(
        AppRoutes.nearStation(
          type: NearStationType.bus,
          id: result.uid,
          name: result.name,
          lat: result.lat,
          lon: result.lon,
          back: _backHere(context),
        ),
      );
    case SearchResultType.bikeStation:
      context.go(
        AppRoutes.nearStation(
          type: NearStationType.bike,
          id: result.uid,
          name: result.name,
          lat: result.lat,
          lon: result.lon,
          back: _backHere(context),
        ),
      );
    case SearchResultType.mrtStation:
      final stationId = metroStationIdForName(result.name);
      unawaited(
        context.push(
          stationId == null
              ? AppRoutes.metro
              : AppRoutes.metroStation(stationId),
        ),
      );
    case SearchResultType.traTrain:
    case SearchResultType.thsrTrain:
      unawaited(
        context.push(
          AppRoutes.railTrain(
            result.uid,
            system: result.type == SearchResultType.traTrain
                ? RailSystem.tra
                : RailSystem.thsr,
          ),
        ),
      );
  }
}

class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key, this.bloc, this.initialQuery});

  /// Text to open the field with, from `/search?q=`. The query runs on the
  /// first frame, so a location that names one lands on its results rather
  /// than on an empty screen with the words already typed.
  final String? initialQuery;

  final SearchBloc? bloc;

  @override
  Widget build(BuildContext context) {
    final bloc = this.bloc;
    return MultiBlocProvider(
      providers: [
        if (bloc == null)
          BlocProvider(create: (_) => SearchBloc())
        else
          BlocProvider.value(value: bloc),
        // Lives with the screen, not with a sheet: opening a result and
        // coming back has to land on the answer that sent you there.
        BlocProvider(create: (_) => GenUiBloc()),
      ],
      child: _SearchView(initialQuery: initialQuery),
    );
  }
}

class _SearchView extends StatefulWidget {
  const _SearchView({this.initialQuery});

  final String? initialQuery;

  @override
  State<_SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<_SearchView> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    final query = widget.initialQuery;
    if (query != null && query.isNotEmpty) {
      _controller.text = query;
      _controller.selection = TextSelection.collapsed(offset: query.length);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      // After the provider is in place: the bloc this dispatches to is
      // installed by the [SearchScreen] above this widget.
      if (query != null && query.isNotEmpty && mounted) {
        context.read<SearchBloc>().add(SearchQueryChanged(query));
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    context.read<SearchBloc>().add(SearchQueryChanged(value));
  }

  /// The debounce means the in-flight query may lag what's on screen; an
  /// explicit submit skips the wait and dismisses the keyboard so the results
  /// aren't left hidden behind it.
  void _onSubmitted(String value) {
    _focusNode.unfocus();
    context.read<SearchBloc>().add(SearchQueryChanged(value));
  }

  void _onClear() {
    _controller.clear();
    context.read<SearchBloc>().add(const SearchCleared());
    _focusNode.requestFocus();
  }

  void _ask(String prompt) {
    final text = prompt.trim();
    if (text.isEmpty) return;
    if (_controller.text.trim() != text) {
      _controller.text = text;
      _controller.selection = TextSelection.collapsed(offset: text.length);
      context.read<SearchBloc>().add(SearchQueryChanged(text));
    }
    _focusNode.unfocus();
    askGenUi(context, text);
  }

  TransportType _transportType(SearchResultType type) => switch (type) {
    SearchResultType.busRoute => TransportType.bus,
    SearchResultType.busStation => TransportType.busStop,
    SearchResultType.bikeStation => TransportType.bike,
    SearchResultType.traTrain => TransportType.tra,
    SearchResultType.thsrTrain => TransportType.thsr,
    SearchResultType.mrtStation => TransportType.mrtBL,
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final topPad = MediaQuery.paddingOf(context).top;
    final bottomPad = MediaQuery.paddingOf(context).bottom;

    return PopScope(
      canPop: context.canPop(),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(AppRoutes.home);
      },
      child: Scaffold(
        backgroundColor: cs.surface,
        body: Column(
          children: [
            Container(
              color: cs.surface,
              padding: EdgeInsets.fromLTRB(
                AppTheme.space16,
                topPad + AppTheme.space12,
                AppTheme.space16,
                AppTheme.space12,
              ),
              child: Row(
                children: [
                  Pressable(
                    onTap: () => _closeSearch(context),
                    semanticLabel: AppI18n.of(context).searchCloseSemantics,
                    // 40pt visual, 48dp touch target: the circle stays the size
                    // the layout wants while the hit area meets the platform
                    // minimum (Pressable hit-tests the whole opaque box).
                    child: SizedBox(
                      width: _minTouchTarget,
                      height: _minTouchTarget,
                      child: Center(
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerLow,
                            shape: BoxShape.circle,
                            boxShadow: AppShadows.cardFor(cs.brightness),
                          ),
                          child: Center(
                            child: Icon(
                              Icons.close_rounded,
                              size: 20,
                              color: cs.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppTheme.space4),
                  Expanded(
                    child: Container(
                      // minHeight, not a fixed height: at large text scales the
                      // field has to grow with its content instead of clipping
                      // it (Settings offers a large-text mode).
                      constraints: const BoxConstraints(
                        minHeight: _minTouchTarget,
                      ),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: AppShadows.cardFor(cs.brightness),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppTheme.space12,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.search_rounded,
                            size: 18,
                            color: cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: AppTheme.space8),
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              focusNode: _focusNode,
                              onChanged: _onChanged,
                              onSubmitted: _onSubmitted,
                              textInputAction: TextInputAction.search,
                              inputFormatters: [
                                LengthLimitingTextInputFormatter(
                                  _maxQueryLength,
                                ),
                              ],
                              style: AppTextStyles.bodyRegular.copyWith(
                                color: cs.onSurface,
                              ),
                              decoration: InputDecoration(
                                hintText: AppI18n.of(context).searchHint,
                                hintStyle: AppTextStyles.bodyRegular.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: AppTheme.space12,
                                ),
                              ),
                            ),
                          ),
                          BlocBuilder<SearchBloc, SearchState>(
                            buildWhen: (p, c) =>
                                p.query.isEmpty != c.query.isEmpty,
                            builder: (context, state) {
                              if (state.query.isEmpty) {
                                return const SizedBox.shrink();
                              }
                              return Pressable(
                                onTap: _onClear,
                                semanticLabel: AppI18n.of(
                                  context,
                                ).searchClearSemantics,
                                child: SizedBox(
                                  width: _minTouchTarget,
                                  height: _minTouchTarget,
                                  child: Center(
                                    child: Container(
                                      width: 18,
                                      height: 18,
                                      decoration: BoxDecoration(
                                        color: cs.onSurfaceVariant,
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        Icons.close_rounded,
                                        size: 12,
                                        color: cs.surfaceContainerLow,
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Above the switcher, not inside it: the answer has to survive the
            // body swapping between recents, results, and empty as the field
            // changes under it.
            BlocBuilder<SearchBloc, SearchState>(
              buildWhen: (p, c) => p.query != c.query,
              builder: (context, state) => GenUiAskLane(
                query: state.query,
                onAsk: _ask,
                onOpen: (result) => _navigateToResult(context, result),
              ),
            ),
            Expanded(
              child: BlocBuilder<SearchBloc, SearchState>(
                builder: (context, state) {
                  final body = _buildBody(context, state, cs, bottomPad);
                  final reduceMotion = MediaQuery.disableAnimationsOf(context);
                  return AnimatedSwitcher(
                    duration: reduceMotion ? Duration.zero : AppMotion.short,
                    switchInCurve: AppMotion.easeOut,
                    switchOutCurve: AppMotion.easeOut,
                    transitionBuilder: AppMotion.switchFade,
                    child: KeyedSubtree(
                      key: ValueKey(_bodyKey(state)),
                      child: body,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _bodyKey(SearchState state) {
    if (state.loading &&
        state.results.isEmpty &&
        state.cityOptions.length < 2) {
      return 'loading';
    }
    if (state.query.isEmpty) return 'recents';
    // With a chip row on screen the chrome is identical across loading,
    // empty, and results, so those share a key: the switcher swaps the list
    // underneath instead of crossfading the chips against themselves.
    if (state.cityOptions.length >= 2 && state.error == null) return 'results';
    if (state.error != null) return 'error';
    if (state.results.isEmpty) return 'empty';
    return 'results';
  }

  Widget _buildBody(
    BuildContext context,
    SearchState state,
    ColorScheme cs,
    double bottomPad,
  ) {
    if (state.loading &&
        state.results.isEmpty &&
        state.cityOptions.length < 2) {
      return const _ResultsSkeleton();
    }

    if (state.query.isEmpty) {
      return const _ZeroInputSuggestions();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          label: AppI18n.of(context).searchResults,
          count: state.error == null ? state.results.length : null,
        ),
        _CityFilterRail(
          options: state.cityOptions,
          selected: state.city,
          onToggle: (code) =>
              context.read<SearchBloc>().add(SearchCityToggled(code)),
        ),
        if (state.loading)
          SizedBox(
            height: 2,
            child: LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: cs.onSurfaceVariant.withValues(alpha: 0.4),
            ),
          ),
        Expanded(
          child: state.error != null
              ? ErrorStateView(
                  error: state.error!,
                  onRetry: () => context.read<SearchBloc>().add(
                    SearchQueryChanged(state.query),
                  ),
                )
              : state.loading && state.results.isEmpty
              // Reloading under a new city filter: "no match" is not the
              // answer yet, so the rows stay skeletal until it is.
              ? const _SkeletonRows()
              : state.results.isEmpty
              ? _NoResults(query: state.query)
              : ListView.separated(
                  // Results sit behind the keyboard on a phone; dragging the
                  // list is the reflex for getting it out of the way.
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.only(
                    bottom: bottomPad + AppTheme.space16,
                  ),
                  itemCount: state.results.length,
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    thickness: 0.5,
                    color: cs.outlineVariant,
                  ),
                  itemBuilder: (context, index) {
                    final result = state.results[index];
                    return _SearchResultRow(
                      result: result,
                      transportType: _transportType(result.type),
                      onTap: () => _navigateToResult(context, result),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Shared header for the recents and results lists, so the two read as one
/// vocabulary rather than two near-identical inline `Text`s.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, this.count, this.trailing});

  final String label;

  /// Rendered as "(n)" beside the label. Null hides it — an unknown count
  /// (error, still loading) shouldn't render as zero.
  final int? count;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final n = count;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space20,
        AppTheme.space6,
        AppTheme.space12,
        AppTheme.space6,
      ),
      color: cs.surface,
      child: Row(
        children: [
          Expanded(
            child: Text(
              n == null ? label : '$label（$n）',
              style: AppTextStyles.bodySmall.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Empty result state. Names the query back to the user and points at what
/// actually works, rather than dead-ending on "找不到結果".
class _NoResults extends StatelessWidget {
  const _NoResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space32,
        AppTheme.space48,
        AppTheme.space32,
        AppTheme.space32,
      ),
      child: Column(
        children: [
          Icon(Icons.search_off_rounded, size: 40, color: cs.onSurfaceVariant),
          const SizedBox(height: AppTheme.space16),
          Text(
            AppI18n.of(context).searchNoMatch(query),
            textAlign: TextAlign.center,
            style: AppTextStyles.bodyLarge.copyWith(
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppTheme.space6),
          Text(
            AppI18n.of(context).searchNoMatchHint,
            textAlign: TextAlign.center,
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// First-load placeholder. Mirrors the result row's metrics so the list
/// doesn't reflow when the real rows arrive.
class _ResultsSkeleton extends StatelessWidget {
  const _ResultsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(label: AppI18n.of(context).searchResults),
        const Expanded(child: _SkeletonRows()),
      ],
    );
  }
}

class _SkeletonRows extends StatelessWidget {
  const _SkeletonRows();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Skeletonizer(
        child: ListView.separated(
          padding: EdgeInsets.zero,
          itemCount: 6,
          separatorBuilder: (_, _) => Divider(
            height: 1,
            thickness: 0.5,
            color: cs.outlineVariant,
          ),
          itemBuilder: (_, i) => _SearchResultRow(
            result: SearchResult(
              type: SearchResultType.busStation,
              uid: 'skeleton-$i',
              name: BoneMock.chars(5, '囗'),
              subtitle: BoneMock.chars(9, '囗'),
            ),
            transportType: TransportType.busStop,
            onTap: () {},
          ),
        ),
      ),
    );
  }
}

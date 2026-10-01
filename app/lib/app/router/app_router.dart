import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/bike/view/bike_station_screen.dart';
import 'package:wheres_the_bus/features/bus/view/bus_route_screen.dart';
import 'package:wheres_the_bus/features/bus/view/bus_stop_screen.dart';
import 'package:wheres_the_bus/features/favorites/view/favorites_screen.dart';
import 'package:wheres_the_bus/features/feedback/view/feedback_screen.dart';
import 'package:wheres_the_bus/features/go/model/planned_place.dart';
import 'package:wheres_the_bus/features/go/view/go_screen.dart';
import 'package:wheres_the_bus/features/home/home_screen.dart';
import 'package:wheres_the_bus/features/metro/view/metro_screen.dart';
import 'package:wheres_the_bus/features/rail/view/rail_screen.dart';
import 'package:wheres_the_bus/features/rail/view/rail_train_screen.dart';
import 'package:wheres_the_bus/features/search/view/search_screen.dart';
import 'package:wheres_the_bus/features/settings/bloc/settings_state.dart';
import 'package:wheres_the_bus/features/settings/settings_option_screen.dart';
import 'package:wheres_the_bus/features/settings/settings_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/rail_system_labels.dart';
import 'package:wheres_the_bus/shared/widgets/main_scaffold.dart';

Page<T> _page<T>(Widget child) => MaterialPage<T>(child: child);

// A stable page key preserves the map instance.
const _homePageKey = ValueKey<String>('home');

Page<void> _homePage(GoRouterState state) => NoTransitionPage(
  key: _homePageKey,
  child: HomeScreen(
    station: NearStationRouteArgs.fromUri(state.uri),
    showRailQuery: state.uri.path == AppRoutes.railQueryPattern,
  ),
);

/// Service date as the train screen wants it, defaulting to today: a location
/// that names no date means "the train running now", not one frozen at the
/// moment the link was made.
String _railDate(DateTime? date) {
  final d = date ?? DateTime.now();
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

const _metroPageKey = ValueKey<String>('metro');

/// Shared by `/metro` and `/metro/station/:id` — the same screen, differing
/// only in whether the location names a station to open on.
Page<void> _metroPage(GoRouterState state) {
  final args = MetroRouteArgs.from(
    state.pathParameters,
    state.uri.queryParameters,
  );
  return MaterialPage(
    key: _metroPageKey,
    child: MetroScreen(stationId: args.stationId, mode: args.mode),
  );
}

/// Reads an optional `{options: List<String>, selected: String}` cache from
/// `state.extra`, falling back to [options]/[selected] when absent so the
/// settings option routes survive cold deep links and state restoration.
Page<T> _settingsOptionPage<T>(
  Object? extra, {
  required String title,
  required List<String> options,
  required String selected,
}) {
  var effectiveOptions = options;
  var effectiveSelected = selected;
  if (extra is Map) {
    final cachedOptions = extra['options'];
    final cachedSelected = extra['selected'];
    if (cachedOptions is List) {
      final parsed = cachedOptions.whereType<String>().toList();
      if (parsed.isNotEmpty) effectiveOptions = parsed;
    }
    if (cachedSelected is String) effectiveSelected = cachedSelected;
  }
  return _page(
    SettingsOptionScreen(
      title: title,
      options: effectiveOptions,
      initialSelected: effectiveSelected,
    ),
  );
}

class _DeferredAnalyticsObserver extends NavigatorObserver {
  FirebaseAnalyticsObserver? _delegate;

  FirebaseAnalyticsObserver? get _observer {
    if (Firebase.apps.isEmpty) return null;
    return _delegate ??= FirebaseAnalyticsObserver(
      analytics: FirebaseAnalytics.instance,
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _observer?.didPush(route, previousRoute);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _observer?.didPop(route, previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _observer?.didReplace(newRoute: newRoute, oldRoute: oldRoute);
}

/// Builds the app's route graph: one [StatefulShellRoute] branch whose shell
/// is [MainScaffold] (banners + floating NavMiniBar over the content).
List<RouteBase> buildAppRoutes({
  bool firebaseEnabled = FirebaseGate.enabled,
}) => [
  StatefulShellRoute.indexedStack(
    builder: (context, state, navigationShell) =>
        MainScaffold(shell: navigationShell),
    branches: [
      StatefulShellBranch(
        observers: firebaseEnabled ? [_DeferredAnalyticsObserver()] : const [],
        routes: [
          GoRoute(
            path: AppRoutes.home,
            pageBuilder: (_, state) => _homePage(state),
          ),
          GoRoute(
            path: AppRoutes.nearStationPattern,
            pageBuilder: (_, state) {
              // A station kind the app does not have is a broken link, not a
              // request for the bare map: opening home anyway would answer it
              // with something that looks like it worked.
              if (NearStationRouteArgs.fromUri(state.uri) == null) {
                return _page(RouteErrorScreen(uri: state.uri));
              }
              return _homePage(state);
            },
          ),
          GoRoute(
            path: AppRoutes.railQueryPattern,
            pageBuilder: (_, state) => _homePage(state),
          ),
          GoRoute(
            path: AppRoutes.settings,
            pageBuilder: (_, _) => _page(const SettingsScreen()),
            routes: [
              // Each picker resolves its own labels rather than relying on the
              // ones the settings screen passed through `extra`, so a cold
              // deep link into the route lands on a fully labelled screen.
              GoRoute(
                path: 'appearance',
                pageBuilder: (context, state) {
                  final i18n = AppI18n.of(context);
                  return _settingsOptionPage<String>(
                    state.extra,
                    title: i18n.settingsAppearance,
                    options: [
                      for (final e in Appearance.values) e.labelOf(i18n),
                    ],
                    selected: Appearance.fromKey(
                      SettingsRepository.instance.appearanceMode,
                    ).labelOf(i18n),
                  );
                },
              ),
              GoRoute(
                path: 'fare-type',
                pageBuilder: (context, state) {
                  final i18n = AppI18n.of(context);
                  return _settingsOptionPage<String>(
                    state.extra,
                    title: i18n.settingsFareType,
                    options: [for (final e in FareType.values) e.labelOf(i18n)],
                    selected: SettingsRepository.instance.fareType.labelOf(
                      i18n,
                    ),
                  );
                },
              ),
              GoRoute(
                path: 'walk-pace',
                pageBuilder: (context, state) {
                  final i18n = AppI18n.of(context);
                  return _settingsOptionPage<String>(
                    state.extra,
                    title: i18n.settingsWalkPace,
                    options: [for (final e in WalkPace.values) e.labelOf(i18n)],
                    selected: WalkPace.fromCmPerSec(
                      SettingsRepository.instance.walkSpeedCmPerSec,
                    ).labelOf(i18n),
                  );
                },
              ),
              GoRoute(
                path: 'language',
                pageBuilder: (context, state) {
                  final i18n = AppI18n.of(context);
                  return _settingsOptionPage<String>(
                    state.extra,
                    title: i18n.settingsLanguage,
                    options: [for (final e in Language.values) e.labelOf(i18n)],
                    selected: Language.fromKey(
                      SettingsRepository.instance.languageCode,
                    ).labelOf(i18n),
                  );
                },
              ),
            ],
          ),
          GoRoute(
            path: AppRoutes.search,
            pageBuilder: (_, state) => _page(
              SearchScreen(initialQuery: state.uri.queryParameters['q']),
            ),
          ),
          GoRoute(
            path: AppRoutes.favorites,
            pageBuilder: (_, _) => _page(const FavoritesScreen()),
          ),
          GoRoute(
            path: AppRoutes.busStop,
            pageBuilder: (_, state) {
              final args = BusStopRouteArgs.from(
                state.uri.queryParameters,
                state.extra,
              );
              if (args == null) return _page(RouteErrorScreen(uri: state.uri));
              return _page(
                BusStopScreen(
                  stopName: args.stopName,
                  stopId: args.stopId,
                  city: args.city,
                  lat: args.lat,
                  lon: args.lon,
                ),
              );
            },
          ),
          GoRoute(
            path: AppRoutes.bikeStation,
            pageBuilder: (_, state) {
              final args = BikeStationRouteArgs.from(
                state.uri.queryParameters,
                state.extra,
              );
              if (args == null) return _page(RouteErrorScreen(uri: state.uri));
              return _page(
                BikeStationScreen(
                  stationUid: args.stationUid,
                  name: args.name,
                  lat: args.lat,
                  lon: args.lon,
                ),
              );
            },
          ),
          GoRoute(
            path: AppRoutes.busRoutePattern,
            pageBuilder: (_, state) {
              final uid = state.pathParameters['subRouteUid'] ?? '';
              if (uid.isEmpty) return _page(RouteErrorScreen(uri: state.uri));
              return _page(BusRouteScreen(subRouteUid: uid));
            },
          ),
          GoRoute(
            path: AppRoutes.rail,
            pageBuilder: (_, state) => _page(
              RailScreen(args: RailRouteArgs.from(state.uri.queryParameters)),
            ),
          ),
          GoRoute(
            path: AppRoutes.metro,
            pageBuilder: (_, state) => _metroPage(state),
          ),
          // A sibling of `/metro` rather than a child: the station detail is a
          // sheet inside the line map's own screen, so nesting would stack a
          // second line map underneath it on a cold deep link.
          GoRoute(
            path: AppRoutes.metroStationPattern,
            pageBuilder: (_, state) => _metroPage(state),
          ),
          GoRoute(
            path: AppRoutes.feedback,
            pageBuilder: (_, state) => _page(
              FeedbackScreen(fromScreen: state.uri.queryParameters['from']),
            ),
          ),
          GoRoute(
            path: AppRoutes.go,
            pageBuilder: (_, state) {
              final args = GoRouteArgs.from(state.uri.queryParameters);
              return _page(
                GoScreen(
                  initialDestination: args == null
                      ? null
                      : PlannedPlace(
                          name: args.name,
                          latLng: LatLng(args.lat, args.lon),
                        ),
                ),
              );
            },
          ),
        ],
      ),
    ],
  ),
  // Outside the shell, not merely on top of it: a full-screen page reached
  // from the home sheet, the rail screen and search alike, so it must cover
  // the banners and must not stack a rail screen underneath.
  GoRoute(
    path: AppRoutes.railTrainPattern,
    pageBuilder: (_, state) {
      final args = RailTrainRouteArgs.from(
        state.pathParameters,
        state.uri.queryParameters,
      );
      if (args == null) return _page(RouteErrorScreen(uri: state.uri));
      final extra = state.extra;
      final warm = extra is RailTrainExtra ? extra : const RailTrainExtra();
      return _page(
        RailTrainScreen(
          type: warm.typeLabel ?? railSystemLabel(args.system),
          trainNo: args.trainNo,
          date: _railDate(args.date),
          userOrigin: warm.userOrigin,
          userDest: warm.userDest,
          delayMinutes: warm.delayMinutes,
          marks: warm.marks,
          remark: warm.remark,
        ),
      );
    },
  ),
];

class AppRouter {
  AppRouter._();

  static final rootNavigatorKey = GlobalKey<NavigatorState>();

  static final GoRouter router = createRouter(navigatorKey: rootNavigatorKey);

  /// Production configuration behind an injectable entry point: tests create
  /// throwaway routers pinned to a deep-link [initialLocation].
  static GoRouter createRouter({
    GlobalKey<NavigatorState>? navigatorKey,
    String initialLocation = AppRoutes.home,
  }) {
    return GoRouter(
      navigatorKey: navigatorKey,
      initialLocation: initialLocation,
      // Survives Android process death: without it the whole stack is lost and
      // a rider who switched apps mid-journey comes back to the home screen.
      restorationScopeId: 'app_router',
      // Cold `wheresthebus:///…` links arrive as a full URL on iOS; strip the
      // scheme so they match the same routes an in-app `go()` does.
      redirect: (_, state) => normalizeDeepLink(state.uri),
      errorPageBuilder: (_, state) => _page(RouteErrorScreen(uri: state.uri)),
      routes: buildAppRoutes(),
    );
  }
}

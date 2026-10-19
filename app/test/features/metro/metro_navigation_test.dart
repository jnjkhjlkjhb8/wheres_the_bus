import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:grpc/grpc.dart';
import 'package:hive_ce/hive.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/models/journey_info.dart';
import 'package:wheres_the_bus/data/models/metro_map_models.dart';
import 'package:wheres_the_bus/data/models/metro_models.dart';
import 'package:wheres_the_bus/data/models/mrt_track_models.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/data/repositories/mrt_repository.dart';
import 'package:wheres_the_bus/data/repositories/mrt_track_repository.dart';
import 'package:wheres_the_bus/data/repositories/near_repository.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/metro_eta_state.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_event.dart';
import 'package:wheres_the_bus/features/metro/data/metro_line_names.dart';
import 'package:wheres_the_bus/features/metro/view/metro_screen.dart';
import 'package:wheres_the_bus/features/metro/view/metro_station_detail_view.dart';
import 'package:wheres_the_bus/features/metro/widgets/metro_svg_map.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_confirm_bar.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_pick_capsule.dart';
import 'package:wheres_the_bus/shared/widgets/app_sliding_segment.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';
import 'package:wheres_the_bus/shared/widgets/transport_icon.dart';

import '../../support/helpers/i18n.dart';
import '../../support/helpers/remote_assets.dart';

class _Location extends GeolocatorPlatform {
  Position? fix;
  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => fix;
}

class _Nearby extends NearRepository {
  List<NearStationViewModel> result = const [];
  Completer<List<NearStationViewModel>>? pending;
  int requests = 0;
  @override
  Stream<List<NearStationViewModel>> nearOnce(
    double lat,
    double lon,
    int radius,
  ) {
    requests++;
    return pending?.future.asStream() ?? Stream.value(result);
  }
}

class _Mrt extends MrtRepository {
  final frames = StreamController<MetroLiveArrival>.broadcast();
  bool matrixFailure = false;
  bool scheduleFailure = false;
  int schedules = 0;
  final matrices = <String>[];
  @override
  Stream<MetroLiveArrival> eta(String system, String stationId) =>
      frames.stream;
  @override
  Future<List<MetroScheduleEntry>> schedule(
    String system,
    String stationId,
  ) async {
    schedules++;
    if (scheduleFailure) throw const GrpcError.unavailable('no schedule');
    return [
      const MetroScheduleEntry(
        line: 'BL',
        destination: 'BL23',
        firstTime: '06:00',
        lastTime: '24:30',
      ),
    ];
  }

  @override
  Future<Map<String, JourneyInfo>> journeyMatrix(String stationId) async {
    matrices.add(stationId);
    if (matrixFailure) throw const GrpcError.unavailable('offline');
    return {
      for (final (code, minutes) in [('BL13', 5), ('BL14', 0), ('BR10', 8)])
        code: JourneyInfo(
          toStationId: code,
          fareNt: 20,
          halfFareNt: 10,
          travelTimeMin: minutes,
        ),
    };
  }
}

class _Tracks extends MrtTrackRepository {
  final pending = Completer<MrtTrackSession>();
  final created = <(String, String, int)>[];
  final cancelled = <String>[];
  @override
  Future<MrtTrackSession> createTrack({
    required String carId,
    required String boardStationId,
    required String destStationId,
    required String targetStationId,
    required int leadStops,
    String vehicleLabel = '',
    String lineCode = '',
    String lineColorHex = '',
  }) {
    created.add((carId, targetStationId, leadStops));
    return pending.future;
  }

  @override
  Future<void> cancel(String id) async => cancelled.add(id);

  void finishPending() {
    if (created.isNotEmpty && !pending.isCompleted) {
      pending.completeError(const GrpcError.cancelled('fixture teardown'));
    }
  }
}

List<Favorite> _savedFavorites = const [];

class _Favorites implements FavoritesRepository {
  @override
  List<Favorite> all() => _savedFavorites;
  @override
  Stream<void> changes() => const Stream.empty();
  @override
  Stream<BoxEvent> watch() => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Position position({double accuracy = 5}) => Position(
  latitude: 25.04,
  longitude: 121.5,
  timestamp: DateTime.now().toUtc(),
  accuracy: accuracy,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

NearStationViewModel nearby(
  String name, {
  NearStationType type = NearStationType.mrt,
}) => NearStationViewModel(
  type: type,
  stationId: 'near',
  stationName: name,
  lat: 25.04,
  lon: 121.5,
  walkingMinutes: 0,
  distanceMeters: 0,
);

Future<void> pumpState(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(seedRemoteAssets);

  late GeolocatorPlatform originalLocation;
  late _Location location;
  setUp(() {
    originalLocation = GeolocatorPlatform.instance;
    location = _Location();
    GeolocatorPlatform.instance = location;
  });
  tearDown(() => GeolocatorPlatform.instance = originalLocation);

  Future<GoRouter> mount(
    WidgetTester tester,
    _Mrt repository,
    _Nearby near, {
    String initial = '/metro',
    MrtTrackBloc? tracking,
    bool dark = false,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final favorites = FavoritesBloc(_Favorites(), ValueNotifier(true));
    final track =
        tracking ??
        MrtTrackBloc(i18n: zhStrings, liveActivityEnabled: () => false);
    Page<void> page(BuildContext _, GoRouterState state) {
      final args = MetroRouteArgs.from(
        state.pathParameters,
        state.uri.queryParameters,
      );
      return MaterialPage(
        key: const ValueKey('metro'),
        child: MetroScreen(
          stationId: args.stationId,
          mode: args.mode,
          repository: repository,
          nearRepository: near,
        ),
      );
    }

    final router = GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(path: AppRoutes.metro, pageBuilder: page),
        GoRoute(path: AppRoutes.metroStationPattern, pageBuilder: page),
      ],
    );
    addTearDown(router.dispose);
    addTearDown(favorites.close);
    addTearDown(track.close);
    addTearDown(repository.frames.close);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        theme: dark ? AppTheme.dark : AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        builder: (context, child) => MultiBlocProvider(
          providers: [
            BlocProvider.value(value: favorites),
            BlocProvider.value(value: track),
          ],
          child: child!,
        ),
      ),
    );
    await pumpState(tester);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets(
    'search selects a station, modes update the URL and close clears it',
    (tester) async {
      final repository = _Mrt();
      final router = await mount(tester, repository, _Nearby());
      await tester.enterText(find.byType(TextField), 'BL13');
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('善導寺'), findsOneWidget);
      await tester.tap(find.text('善導寺'));
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        router.routeInformationProvider.value.uri.path,
        '/metro/station/BL13',
      );
      expect(repository.matrices, contains('BL13'));
      expect(find.text(zhStrings.metroMapModeTime), findsOneWidget);
      await tester.tap(find.text(zhStrings.metroMapModeFare));
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        router.routeInformationProvider.value.uri.queryParameters['mode'],
        'fare',
      );
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/metro');
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text(zhStrings.metroMapModeFare), findsNothing);
      await tester.enterText(find.byType(TextField), 'no such station');
      await pumpState(tester);
      expect(find.text('善導寺'), findsNothing);
      await tester.tap(find.byIcon(Icons.clear_rounded));
      await pumpState(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      tester
          .widget<MetroSvgMap>(find.byType(MetroSvgMap))
          .onStationTap(
            metroMapStations.firstWhere((station) => station.id == 'BL01'),
          );
      await pumpState(tester);
      expect(
        router.routeInformationProvider.value.uri.path,
        '/metro/station/BL01',
      );
      await tester.binding.handlePopRoute();
      await pumpState(tester);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/metro');
      expect(find.byType(TextField), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed local matrices retry and real arrival frames replace loading',
    (tester) async {
      final repository = _Mrt()..matrixFailure = true;
      await mount(
        tester,
        repository,
        _Nearby(),
        initial: '/metro/station/BL13',
      );
      repository.matrixFailure = false;
      await tester.drag(find.byType(SheetDragHandle), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(zhStrings.commonRetry));
      await pumpState(tester);
      await tester.tap(find.text(zhStrings.commonRetry));
      await pumpState(tester);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(find.text('善導寺'), findsOneWidget);
      expect(repository.frames.hasListener, isTrue);
      repository.frames.add(
        const MetroLiveArrival(
          line: 'BL',
          destination: '南港展覽館',
          estimateSeconds: 120,
          system: 'TRTC',
          stationId: 'BL13',
          destinationStationId: 'BL23',
          trainNumber: '215',
        ),
      );
      await pumpState(tester);
      await tester.pump(const Duration(milliseconds: 700));
      await pumpState(tester);
      final eta = tester
          .element(find.byType(RefreshIndicator))
          .read<MetroEtaBloc>();
      expect(eta.state.arrivals, isNotEmpty);
      expect(find.text(zhStrings.towardsSpaced('南港展覽館')), findsWidgets);
      repository.frames.addError(const GrpcError.unauthenticated('feed lost'));
      await pumpState(tester);
      await pumpState(tester);
      expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
      expect(find.text(zhStrings.towardsSpaced('南港展覽館')), findsWidgets);
      final before = repository.schedules;
      await tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pump(const Duration(milliseconds: 1500));
      await pumpState(tester);
      expect(repository.schedules, greaterThan(before));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('empty arrival failures reload the real station subscription', (
    tester,
  ) async {
    final repository = _Mrt()..scheduleFailure = true;
    await mount(tester, repository, _Nearby(), initial: '/metro/station/BL13');
    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
    expect(find.text(zhStrings.metroEtaUnavailable), findsOneWidget);
    repository.scheduleFailure = false;
    await tester.drag(find.byType(SheetDragHandle), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(zhStrings.commonReload));
    final eta = tester
        .element(find.byType(RefreshIndicator))
        .read<MetroEtaBloc>();
    final emptyEta = tester
        .element(find.byType(MetroArrivalsEmpty))
        .read<MetroEtaBloc>();
    expect(identical(eta, emptyEta), isTrue);
    expect(eta.isClosed, isFalse);
    expect(repository.frames.hasListener, isTrue);
    expect(repository.schedules, 1);
    final reloaded = <MetroEtaState>[];
    final states = eta.stream.listen(reloaded.add);
    addTearDown(states.cancel);
    tester
        .widget<MetroArrivalsEmpty>(find.byType(MetroArrivalsEmpty))
        .onRetry!();
    // Cancelling the native stream must finish outside the widget fake clock.
    await tester.runAsync(pumpEventQueue);
    await pumpState(tester);
    await tester.pump(const Duration(milliseconds: 100));
    await pumpState(tester);
    final currentEta = tester
        .element(find.byType(RefreshIndicator))
        .read<MetroEtaBloc>();
    expect(identical(eta, currentEta), isTrue);
    expect(
      repository.schedules,
      2,
      reason:
          'closed=${eta.isClosed}, listening=${repository.frames.hasListener}, '
          'emitted=${reloaded.map((s) => (s.loading, s.error))}',
    );
    expect(reloaded.any((state) => state.loading), isTrue);
    repository.frames.add(
      const MetroLiveArrival(
        line: 'BL',
        destination: '南港展覽館',
        estimateSeconds: 120,
      ),
    );
    await pumpState(tester);
    await pumpState(tester);
    expect(find.text(zhStrings.towardsSpaced('南港展覽館')), findsWidgets);
    expect(find.byIcon(Icons.cloud_off_rounded), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'system picker announces a selected future network and cancels safely',
    (tester) async {
      await mount(tester, _Mrt(), _Nearby());
      await tester.tap(find.text(zhStrings.metroSystemTrtc));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuItem<String>).first);
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        find.text(zhStrings.comingSoonValue(zhStrings.metroSystemKrtc)),
        findsOneWidget,
      );
      await tester.tap(find.text(zhStrings.metroSystemTrtc));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(350, 600));
      await tester.pumpAndSettle();
      expect(find.text(zhStrings.metroSystemKrtc), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('system picker opens under the pill and flips its chevron', (
    tester,
  ) async {
    await mount(tester, _Mrt(), _Nearby());
    final pill = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_SystemPill',
    );
    final pillRect = tester.getRect(pill);
    double turns() => tester
        .widget<AnimatedRotation>(
          find.descendant(of: pill, matching: find.byType(AnimatedRotation)),
        )
        .turns;
    expect(turns(), 0.0);

    await tester.tap(find.text(zhStrings.metroSystemTrtc));
    await tester.pumpAndSettle();
    expect(turns(), 0.5);

    final menu = find.byWidgetPredicate(
      (w) =>
          w is Material &&
          w.shape is RoundedRectangleBorder &&
          (w.shape! as RoundedRectangleBorder).borderRadius ==
              BorderRadius.circular(16),
    );
    final menuRect = tester.getRect(menu);
    expect(menuRect.left, pillRect.left);
    expect(menuRect.width, pillRect.width);
    expect(menuRect.top, pillRect.bottom + 4);

    await tester.tapAt(const Offset(350, 600));
    await tester.pumpAndSettle();
    expect(turns(), 0.0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('placeholder sheet', () {
    final placeholder = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_MetroPlaceholderSheet',
    );
    final lists = find.descendant(
      of: placeholder,
      matching: find.byType(ListView),
    );
    const bl13 = Favorite(
      type: FavoriteType.metroStation,
      refId: 'BL13',
      title: '善導寺',
    );
    const bl12 = Favorite(
      type: FavoriteType.metroStation,
      refId: 'BL10',
      title: '龍山寺',
    );
    const bus = Favorite(
      type: FavoriteType.busStop,
      refId: 'BL01',
      title: '頂埔',
    );

    setUp(() => _savedFavorites = const []);
    tearDown(() => _savedFavorites = const []);

    ColorScheme scheme(WidgetTester tester) =>
        Theme.of(tester.element(placeholder)).colorScheme;

    testWidgets('with no favourites it explains how to add one', (
      tester,
    ) async {
      await mount(tester, _Mrt(), _Nearby());
      final hint = tester.widget<Text>(
        find.text(zhStrings.metroNoFavoriteStations),
      );
      expect(hint.style!.height, 1.5);
      expect(
        find.byType(Icon).evaluate().where((e) {
          final icon = e.widget as Icon;
          return icon.icon == Icons.arrow_forward_ios_rounded;
        }),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('only metro favourites are listed, with a 14px chevron', (
      tester,
    ) async {
      _savedFavorites = const [bl13, bus];
      await mount(tester, _Mrt(), _Nearby());
      await tester.pump();
      expect(find.text('善導寺'), findsOneWidget);
      expect(find.text('頂埔'), findsNothing);
      final chevron = tester.widget<Icon>(
        find.descendant(
          of: placeholder,
          matching: find.byIcon(Icons.arrow_forward_ios_rounded),
        ),
      );
      expect(chevron.size, 14);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('favourite rows pad for the keyboard and use 30% dividers', (
      tester,
    ) async {
      _savedFavorites = const [bl13, bl12, bus];
      await mount(tester, _Mrt(), _Nearby());
      await tester.pump();
      unawaited(
        ((tester.widget(placeholder) as dynamic).sheetController
                as SheetController)
            .animateToDetent(AppSheetSnap.full, reduced: true),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<ListView>(lists).padding,
        const EdgeInsets.fromLTRB(16, 0, 16, 32),
      );
      final divider = tester.widget<Divider>(
        find.descendant(of: placeholder, matching: find.byType(Divider)).first,
      );
      expect(
        divider.color,
        scheme(tester).outlineVariant.withValues(alpha: 0.3),
      );
      expect(divider.height, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the field is rounded 12 and clears its own query', (
      tester,
    ) async {
      await mount(tester, _Mrt(), _Nearby());
      final field = tester.widget<TextField>(
        find.descendant(of: placeholder, matching: find.byType(TextField)),
      );
      final border = field.decoration!.border! as OutlineInputBorder;
      expect(border.borderRadius, BorderRadius.circular(12));
      expect(find.byIcon(Icons.clear_rounded), findsNothing);

      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pump();
      expect(find.text(zhStrings.metroNoStationMatch('zzzz')), findsOneWidget);
      expect(find.text(zhStrings.metroSearchNoMatchHint), findsOneWidget);
      expect(find.text(zhStrings.metroNoFavoriteStations), findsNothing);

      await tester.tap(find.byIcon(Icons.clear_rounded));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(find.byIcon(Icons.clear_rounded), findsNothing);
      expect(find.text(zhStrings.metroNoFavoriteStations), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('search matches ids and names', (
      tester,
    ) async {
      await mount(tester, _Mrt(), _Nearby());
      await tester.enterText(find.byType(TextField), 'bl13');
      await tester.pump();
      expect(find.text('善導寺'), findsOneWidget);
      expect(
        tester.widget<ListView>(lists).padding,
        const EdgeInsets.fromLTRB(16, 0, 16, 32),
      );
      await tester.enterText(find.byType(TextField), '善導');
      await tester.pump();
      expect(find.text('善導寺'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('focusing the field lifts the sheet; blurring leaves it', (
      tester,
    ) async {
      await mount(tester, _Mrt(), _Nearby());
      final controller =
          (tester.widget(placeholder) as dynamic).sheetController
              as SheetController;
      final resting = controller.metrics!.offset;

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      final lifted = controller.metrics!.offset;
      expect(lifted, greaterThan(resting));

      unawaited(controller.animateToDetent(AppSheetSnap.peek, reduced: true));
      await tester.pumpAndSettle();
      final lowered = controller.metrics!.offset;
      expect(lowered, lessThan(lifted));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(controller.metrics!.offset, lowered);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('metro screen details', () {
    List<String> recordHaptics(WidgetTester tester) {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            calls.add('${call.arguments}');
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      return calls;
    }

    Finder chip() => find.byKey(const ValueKey('map-mode-chip'));

    testWidgets('favourite rows name their line and wear its icon', (
      tester,
    ) async {
      _savedFavorites = [
        for (final id in ['BL13', 'BR02', 'G06', 'R04', 'O17_Y18', 'Y09'])
          Favorite(
            type: FavoriteType.metroStation,
            refId: id,
            title: id,
          ),
      ];
      addTearDown(() => _savedFavorites = const []);
      await mount(tester, _Mrt(), _Nearby());
      await tester.pump();
      unawaited(
        ((tester.widget(
                          find.byWidgetPredicate(
                            (w) =>
                                w.runtimeType.toString() ==
                                '_MetroPlaceholderSheet',
                          ),
                        )
                        as dynamic)
                    .sheetController
                as SheetController)
            .animateToDetent(
              AppSheetSnap.full,
              reduced: true,
            ),
      );
      await tester.pumpAndSettle();
      final names = metroLineNames(zhStrings);
      for (final (station, line, type) in [
        ('善導寺', 'BL', TransportType.mrtBL),
        ('木柵', 'BR', TransportType.mrtBR),
        ('萬隆', 'G', TransportType.mrtG),
        ('信義安和', 'R', TransportType.mrtR),
        ('頭前庄', 'O', TransportType.mrtO),
        ('秀朗橋', 'Y', TransportType.mrtBL),
      ]) {
        final row = find.widgetWithText(Pressable, station);
        expect(row, findsOneWidget, reason: station);
        expect(
          find.descendant(of: row, matching: find.text(names[line] ?? line)),
          findsOneWidget,
          reason: station,
        );
        expect(
          tester
              .widget<TransportIcon>(
                find.descendant(of: row, matching: find.byType(TransportIcon)),
              )
              .type,
          type,
          reason: station,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the screen background follows the theme', (tester) async {
      await mount(tester, _Mrt(), _Nearby());
      Scaffold scaffold() => tester.widget<Scaffold>(
        find
            .ancestor(
              of: find.byType(MetroSvgMap),
              matching: find.byType(Scaffold),
            )
            .first,
      );
      expect(scaffold().backgroundColor, Colors.white);
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(tester, _Mrt(), _Nearby(), dark: true);
      expect(scaffold().backgroundColor, const Color(0xFF0C0C0C));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('picking a station buzzes once and reveals the mode chip', (
      tester,
    ) async {
      final haptics = recordHaptics(tester);
      await mount(tester, _Mrt(), _Nearby());
      expect(chip(), findsNothing);
      await tester.enterText(find.byType(TextField), 'BL13');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.tap(find.text('善導寺'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(haptics.where((h) => h.contains('lightImpact')), hasLength(1));
      expect(chip(), findsOneWidget);
      final scale = tester.widget<ScaleTransition>(
        find.ancestor(of: chip(), matching: find.byType(ScaleTransition)).first,
      );
      expect(scale.scale.value, inInclusiveRange(0.9, 1));
      final slide = tester.widget<SlideTransition>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('detail:BL13')),
              matching: find.byType(SlideTransition),
            )
            .first,
      );
      expect(slide.position.value.dy, inInclusiveRange(0, 0.04));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('an automatic nearby pick does not buzz', (tester) async {
      final haptics = recordHaptics(tester);
      location.fix = position();
      final near = _Nearby()..result = [nearby('善導寺')];
      await mount(tester, _Mrt(), near);
      expect(haptics.where((h) => h.contains('lightImpact')), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the mode chip switches the labels and keeps the station', (
      tester,
    ) async {
      final router = await mount(
        tester,
        _Mrt(),
        _Nearby(),
        initial: '/metro/station/BL13',
      );
      await tester.pump(const Duration(milliseconds: 700));
      MetroMapMode value() => tester
          .widget<AppSlidingSegment<MetroMapMode>>(
            find.byType(AppSlidingSegment<MetroMapMode>),
          )
          .value;
      expect(value(), MetroMapMode.time);
      await tester.tap(find.text(zhStrings.metroMapModeFare));
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        router.routeInformationProvider.value.uri.path,
        '/metro/station/BL13',
      );
      expect(value(), MetroMapMode.fare);
      expect(
        tester
            .widget<MetroSvgMap>(find.byType(MetroSvgMap))
            .stationLabels
            .values,
        contains('20'),
      );
      await tester.tap(find.text(zhStrings.metroMapModeTime));
      await tester.pump(const Duration(milliseconds: 700));
      expect(value(), MetroMapMode.time);
      expect(
        tester
            .widget<MetroSvgMap>(find.byType(MetroSvgMap))
            .stationLabels
            .values,
        contains('8'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('a fresh accurate nearby MRT fix selects its known station', (
    tester,
  ) async {
    location.fix = position();
    final near = _Nearby()
      ..result = [nearby('善導寺'), nearby('bus', type: NearStationType.bus)];
    final router = await mount(tester, _Mrt(), near);
    expect(near.requests, 1);
    expect(
      router.routeInformationProvider.value.uri.path,
      '/metro/station/BL13',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an inaccurate fix never requests nearby stations', (
    tester,
  ) async {
    location.fix = position(accuracy: 1000);
    final near = _Nearby();
    final router = await mount(tester, _Mrt(), near, dark: true);
    expect(
      tester.widget<TextField>(find.byType(TextField)).decoration!.fillColor,
      AppTheme.dark.colorScheme.surfaceContainerHigh,
    );
    expect(near.requests, 0);
    expect(router.routeInformationProvider.value.uri.path, '/metro');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a delayed nearby answer cannot replace a rider selection', (
    tester,
  ) async {
    location.fix = position();
    final pending = Completer<List<NearStationViewModel>>();
    final near = _Nearby()..pending = pending;
    final router = await mount(tester, _Mrt(), near);
    router.go('/metro/station/BL01');
    await tester.pump(const Duration(milliseconds: 700));
    pending.complete([nearby('善導寺')]);
    await tester.pump(const Duration(milliseconds: 700));
    expect(
      router.routeInformationProvider.value.uri.path,
      '/metro/station/BL01',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'alight pick binds the carriage, repicks and reports creation failure',
    (tester) async {
      final repository = _Mrt();
      final tracks = _Tracks();
      final track = MrtTrackBloc(
        i18n: zhStrings,
        repository: tracks,
        liveActivityEnabled: () => false,
      );
      await mount(
        tester,
        repository,
        _Nearby(),
        initial: '/metro/station/BL13',
        tracking: track,
      );
      addTearDown(tracks.finishPending);
      repository.frames.add(
        const MetroLiveArrival(
          line: 'BL',
          destination: '南港展覽館',
          estimateSeconds: 120,
          system: 'TRTC',
          stationId: 'BL13',
          destinationStationId: 'BL23',
          trainNumber: '215',
          cn1: '163/164',
        ),
      );
      await pumpState(tester);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.tap(find.byIcon(Icons.notifications_none_rounded));
      await pumpState(tester);
      expect(track.state.picking, isTrue);
      tester
          .widget<MetroSvgMap>(find.byType(MetroSvgMap))
          .onStationTap(metroMapStations.firstWhere((s) => s.id == 'BL14_O07'));
      await pumpState(tester);
      expect(track.state.pickTargetStationId, 'BL14');
      expect(
        tester.widget<MetroSvgMap>(find.byType(MetroSvgMap)).pickAheadIds,
        contains('BL14_O07'),
      );
      expect(
        tester.widget<MetroSvgMap>(find.byType(MetroSvgMap)).pickedStationId,
        'BL14_O07',
      );
      final bar = tester.widget<AlightConfirmBar>(
        find.byType(AlightConfirmBar),
      );
      expect(bar.canStart, isTrue);
      expect(find.text(zhStrings.metroCarChip('1163')), findsOneWidget);
      bar.onLeadChanged(2);
      await pumpState(tester);
      await tester.tap(find.text(zhStrings.alightRepick));
      await pumpState(tester);
      expect(find.byType(AlightConfirmBar), findsNothing);
      expect(track.state.picking, isTrue);
      tester
          .widget<MetroSvgMap>(find.byType(MetroSvgMap))
          .onStationTap(
            metroMapStations.firstWhere((s) => s.id == 'BL15_BR10'),
          );
      await pumpState(tester);
      await tester.tap(find.text(zhStrings.mrtAlightStart));
      await pumpState(tester);
      expect(tracks.created, [('1163', 'BL15', 2)]);
      expect(
        tester.widget<AlightConfirmBar>(find.byType(AlightConfirmBar)).busy,
        isTrue,
      );
      tracks.pending.completeError(
        const GrpcError.invalidArgument('unreachable'),
      );
      await pumpState(tester);
      expect(find.text(zhStrings.mrtAlightNotReachable), findsOneWidget);
      tester.widget<AlightConfirmBar>(find.byType(AlightConfirmBar)).onCancel();
      await pumpState(tester);
      expect(track.state.picking, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'unpaired carriage requires digits and unknown picked targets have no dock',
    (tester) async {
      final tracks = _Tracks();
      final track = MrtTrackBloc(
        i18n: zhStrings,
        repository: tracks,
        liveActivityEnabled: () => false,
      );
      await mount(
        tester,
        _Mrt(),
        _Nearby(),
        initial: '/metro/station/BL13',
        tracking: track,
      );
      addTearDown(tracks.finishPending);
      track
        ..add(
          const MrtAlightPickStarted(
            MetroArrival(
              line: 'BL',
              destination: '南港展覽館',
              estimateSeconds: 90,
              system: 'TRTC',
              stationId: 'BL13',
              destinationStationId: 'BL23',
            ),
          ),
        )
        ..add(const MrtAlightTargetPicked('UNKNOWN'));
      await pumpState(tester);
      expect(find.byType(AlightConfirmBar), findsNothing);
      track.add(const MrtAlightTargetPicked('BL14'));
      await pumpState(tester);
      expect(
        tester.widget<AlightConfirmBar>(find.byType(AlightConfirmBar)).canStart,
        isFalse,
      );
      await tester.enterText(find.byType(TextField), 'a1163');
      await pumpState(tester);
      expect(
        tester.widget<AlightConfirmBar>(find.byType(AlightConfirmBar)).canStart,
        isTrue,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '1163',
      );
      final carField = tester.widget<TextField>(find.byType(TextField));
      expect(carField.style!.fontSize, 16);
      expect(carField.decoration!.hintStyle!.fontSize, 16);
      expect(
        (carField.decoration!.border! as OutlineInputBorder).borderRadius,
        BorderRadius.circular(AppTheme.radiusButton),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlightPickCapsule),
          matching: find.byIcon(Icons.close_rounded),
        ),
      );
      await pumpState(tester);
      expect(find.byType(AlightConfirmBar), findsNothing);
      track.add(
        const MrtAlightPickStarted(
          MetroArrival(
            line: 'O',
            destination: '迴龍',
            estimateSeconds: 90,
            system: 'TRTC',
            stationId: 'O06',
            destinationStationId: 'O12',
          ),
        ),
      );
      await pumpState(tester);
      tester
          .widget<MetroSvgMap>(find.byType(MetroSvgMap))
          .onStationTap(metroMapStations.firstWhere((s) => s.id == 'BL14_O07'));
      await pumpState(tester);
      expect(track.state.pickTargetStationId, 'O07');
      expect(
        tester
            .widget<AlightConfirmBar>(find.byType(AlightConfirmBar))
            .targetName,
        '忠孝新生',
      );
      tester.widget<AlightConfirmBar>(find.byType(AlightConfirmBar)).onStart();
      await pumpState(tester);
      expect(tracks.created, [('1163', 'O07', 0)]);
      tracks.pending.completeError(
        const GrpcError.notFound('missing carriage'),
      );
      await pumpState(tester);
      expect(find.text(zhStrings.mrtAlightNotFound), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('armed bell manages, closes and cancels its live reminder', (
    tester,
  ) async {
    final repository = _Mrt();
    final tracks = _Tracks();
    final track = MrtTrackBloc(
      i18n: zhStrings,
      repository: tracks,
      liveActivityEnabled: () => false,
      vibrate: (_, _) async {},
    );
    await mount(
      tester,
      repository,
      _Nearby(),
      initial: '/metro/station/BL13',
      tracking: track,
    );
    repository.frames.add(
      const MetroLiveArrival(
        line: 'BL',
        destination: '南港展覽館',
        estimateSeconds: 120,
        system: 'TRTC',
        stationId: 'BL13',
        destinationStationId: 'BL23',
        trainNumber: '215',
      ),
    );
    track.add(
      MrtTrackUpdated(
        MrtTrackSession.fromJson(const {
          'trackId': 'saved',
          'tripId': '215',
          'status': 'tracking',
          'pathStationIds': ['BL13', 'BL14'],
          'pathStationNames': ['善導寺', '忠孝新生'],
          'targetIndex': 1,
        }),
      ),
    );
    await pumpState(tester);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.tap(find.byIcon(Icons.notifications_active_rounded));
    await pumpState(tester);
    expect(find.byType(AlightManageBar), findsOneWidget);
    tester.widget<AlightManageBar>(find.byType(AlightManageBar)).onClose();
    await pumpState(tester);
    expect(find.byType(AlightManageBar), findsNothing);
    await tester.tap(find.byIcon(Icons.notifications_active_rounded));
    await pumpState(tester);
    tester.widget<AlightManageBar>(find.byType(AlightManageBar)).onCancel();
    await pumpState(tester);
    expect(track.state.session, isNull);
    expect(tracks.cancelled, ['saved']);
    expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'an armed bell shows the latest target when its session updates',
    (
      tester,
    ) async {
      final repository = _Mrt();
      final track = MrtTrackBloc(
        i18n: zhStrings,
        repository: _Tracks(),
        liveActivityEnabled: () => false,
        vibrate: (_, _) async {},
      );
      await mount(
        tester,
        repository,
        _Nearby(),
        initial: '/metro/station/BL13',
        tracking: track,
      );
      repository.frames.add(
        const MetroLiveArrival(
          line: 'BL',
          destination: '南港展覽館',
          estimateSeconds: 120,
          system: 'TRTC',
          stationId: 'BL13',
          destinationStationId: 'BL23',
          trainNumber: '215',
        ),
      );
      MrtTrackSession session(String target) => MrtTrackSession.fromJson({
        'trackId': 'saved',
        'tripId': '215',
        'status': 'tracking',
        'pathStationIds': const ['BL13', 'BL14'],
        'pathStationNames': ['善導寺', target],
        'targetIndex': 1,
      });
      track.add(MrtTrackUpdated(session('忠孝新生')));
      await pumpState(tester);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.tap(find.byIcon(Icons.notifications_active_rounded));
      await pumpState(tester);
      expect(
        tester.widget<AlightManageBar>(find.byType(AlightManageBar)).targetName,
        '忠孝新生',
      );
      track.add(MrtTrackUpdated(session('南京復興')));
      await pumpState(tester);
      expect(
        tester.widget<AlightManageBar>(find.byType(AlightManageBar)).targetName,
        '南京復興',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

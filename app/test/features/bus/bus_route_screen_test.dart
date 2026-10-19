import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/bus_route_detail.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_bloc.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/features/bus/view/bus_route_screen.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_confirm_bar.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_pick_capsule.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_swipe_row.dart';
import 'package:wheres_the_bus/shared/widgets/app_accordion.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/app_sliding_segment.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';

import '../../support/fakes/map_platform.dart';

class _RouteLocation extends GeolocatorPlatform {
  Position? cached;

  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => cached;
}

const _goStops = [
  BusStopModel(
    stopUid: 'A',
    stopName: 'Start',
    sequence: 1,
    lat: 25,
    lon: 121,
  ),
  BusStopModel(
    stopUid: 'B',
    stopName: 'Middle',
    sequence: 2,
    lat: 25.001,
    lon: 121.001,
  ),
  BusStopModel(
    stopUid: 'C',
    stopName: 'Buffer',
    sequence: 3,
    lat: 25.002,
    lon: 121.002,
  ),
  BusStopModel(
    stopUid: 'D',
    stopName: 'End',
    sequence: 4,
    lat: 25.003,
    lon: 121.003,
  ),
];

class _Bus extends BusRepository {
  _Bus({
    this.fail = false,
    this.details = false,
    this.odFares = false,
    this.overflowFares = false,
    this.missingEndpoints = false,
    this.emptyStops = false,
    this.operatorUrl = 'https://operator.example/route',
    this.operatorPhone = '(02)2999-2020',
    this.manyTrips = false,
    this.returnOnly = false,
    this.sectionFare = false,
    this.emptyCity = false,
    this.odPlan,
    this.odFlatPrice = false,
    this.onlyFullFare = false,
    this.singleStop = false,
    this.startName = 'Start',
    this.endName = 'End',
  });
  bool fail;
  final bool emptyCity;

  /// Origins and how many destinations each lists; overrides the default OD
  /// fixture. Destinations are named `<origin>-<index>`.
  final List<(String, int)>? odPlan;
  final bool odFlatPrice;
  final bool onlyFullFare;
  final bool singleStop;
  final String startName;
  final String endName;
  final bool details;
  final bool odFares;
  final bool overflowFares;
  final bool missingEndpoints;
  final bool emptyStops;
  final String operatorUrl;
  final String operatorPhone;
  final bool manyTrips;
  final bool returnOnly;
  final bool sectionFare;
  final frames = StreamController<List<BusStopEtaViewModel>>.broadcast();
  int loads = 0;

  @override
  Future<BusRouteViewModel> routeStatic(String subRouteUid) async {
    loads++;
    if (fail) throw StateError('route unavailable');
    return BusRouteViewModel(
      subRouteUid: subRouteUid,
      routeName: '307',
      subRouteName: '',
      departureStopName: missingEndpoints ? '' : startName,
      destinationStopName: missingEndpoints ? '' : endName,
      city: emptyCity ? '' : 'Taipei',
      headsignGo: missingEndpoints ? '' : '往 End',
      headsignReturn: missingEndpoints ? '' : '往 Start',
      operators: details
          ? [
              BusOperatorInfo(
                name: 'Test operator',
                phone: operatorPhone,
                url: operatorUrl,
              ),
              const BusOperatorInfo(name: '', phone: '', url: ''),
            ]
          : const [],
      schedulesGo: details
          ? const [
              BusServiceEntry(
                isTimetable: true,
                serviceDay: 31,
                departureTime: '00:00',
                isLowFloor: true,
              ),
              BusServiceEntry(
                isTimetable: false,
                serviceDay: 31,
                startTime: '06:00',
                endTime: '22:00',
                minHeadwayMins: '10',
                maxHeadwayMins: '15',
              ),
            ]
          : const [],
      stopsGo: emptyStops || returnOnly
          ? const []
          : _goStops.take(singleStop ? 1 : _goStops.length).toList(),
      stopsReturn: emptyStops
          ? const []
          : const [
              BusStopModel(
                stopUid: 'D',
                stopName: 'Return start',
                sequence: 1,
                lat: 25.003,
                lon: 121.003,
              ),
              BusStopModel(
                stopUid: 'A',
                stopName: 'Return end',
                sequence: 2,
                lat: 25,
                lon: 121,
              ),
            ],
      fare: BusFareInfo(
        pricingType: sectionFare ? 2 : (details ? 1 : 0),
        isFreeBus: false,
        sectionFaresJson: utf8.encode(
          jsonEncode([
            {
              'BufferZones': [
                if (sectionFare) {'StopSequence': 2},
                {'StopSequence': 3},
              ],
              if (details && !odFares)
                'Fares': [
                  {'FareClass': 1, 'Price': 15},
                  if (!onlyFullFare) {'FareClass': 10, 'Price': 8},
                ],
            },
          ]),
        ),
        stageFaresJson: const [],
        odFaresJson: odPlan != null
            ? utf8.encode(
                jsonEncode([
                  for (final (origin, count) in odPlan!)
                    for (var i = 0; i < count; i++)
                      {
                        'OriginStop': {'StopName': origin},
                        'DestinationStop': {'StopName': '$origin-$i'},
                        'Fares': [
                          {'FareClass': 1, 'Price': odFlatPrice ? 20 : 20 + i},
                        ],
                      },
                ]),
              )
            : odFares
            ? utf8.encode(
                jsonEncode([
                  for (final (destination, price)
                      in overflowFares
                          ? [
                              for (var index = 0; index < 81; index++)
                                ('Stop-$index', 20 + index),
                            ]
                          : [('Harbor', 20), ('Park', 35), ('Museum', 50)])
                    {
                      'OriginStop': {'StopName': 'Central'},
                      'DestinationStop': {'StopName': destination},
                      'Fares': [
                        {'FareClass': 1, 'Price': price},
                        {'FareClass': 10, 'Price': price ~/ 2},
                      ],
                    },
                  if (overflowFares)
                    {
                      'OriginStop': {'StopName': 'Second origin'},
                      'DestinationStop': {'StopName': 'Last destination'},
                      'Fares': [
                        {'FareClass': 1, 'Price': 100},
                      ],
                    },
                ]),
              )
            : const [],
      ),
    );
  }

  @override
  Future<BusDailyTimetable> routeDaily(String subRouteUid) async => details
      ? BusDailyTimetable(
          directions: {
            0: [
              for (final (index, time)
                  in (manyTrips
                          ? List.filled(20, '23:59')
                          : ['00:00', '01:00', '02:00', '23:58', '23:59'])
                      .indexed)
                BusDailyTrip(
                  tripId: 'trip-$index',
                  isLowFloor: index == 0,
                  stopTimes: [
                    BusStopTime(
                      stopSequence: 1,
                      departureTime: time,
                      arrivalTime: time,
                    ),
                  ],
                ),
            ],
          },
        )
      : const BusDailyTimetable();
  @override
  Stream<List<BusStopEtaViewModel>> routeEta(String subRouteUid) =>
      frames.stream;
}

void main() {
  late GoogleMapsFlutterPlatform previousMap;
  late FakeMapPlatform map;
  late GeolocatorPlatform previousLocation;
  late _RouteLocation location;
  setUpAll(() async {
    for (final name in [
      'settings',
      'favorites',
      'fav_routes',
      'arrival_reminders',
    ]) {
      await Hive.openBox<dynamic>(name, bytes: Uint8List(0));
    }
  });
  tearDownAll(() async {
    await Hive.close();
  });
  setUp(() {
    previousMap = GoogleMapsFlutterPlatform.instance;
    map = FakeMapPlatform();
    GoogleMapsFlutterPlatform.instance = map;
    previousLocation = GeolocatorPlatform.instance;
    location = _RouteLocation();
    GeolocatorPlatform.instance = location;
  });
  tearDown(() {
    GoogleMapsFlutterPlatform.instance = previousMap;
    GeolocatorPlatform.instance = previousLocation;
  });

  Future<void> pump(
    WidgetTester tester,
    _Bus bus, {
    JourneySessionBloc? journey,
    bool reduced = false,
    bool? dark,
    double textScale = 1,
  }) async {
    addTearDown(bus.frames.close);
    final ready = ValueNotifier(true);
    addTearDown(ready.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: (dark ?? reduced) ? AppTheme.dark : AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reduced,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: MultiBlocProvider(
          providers: [
            BlocProvider(
              create: (_) =>
                  journey ??
                  JourneySessionBloc(
                    etaStream: (_) => const Stream.empty(),
                    liveActivityEnabled: () => false,
                  ),
            ),
            BlocProvider(
              create: (_) => FavoritesBloc(FavoritesRepository.instance, ready),
            ),
          ],
          child: BusRouteScreen(subRouteUid: 'R', repository: bus),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (
      var frame = 0;
      frame < 12 && map.cameraUpdates.isEmpty && !bus.fail;
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
    }
  }

  Future<void> flushLive(WidgetTester tester) async {
    for (var frame = 0; frame < 6; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  void sendVehicles(_Bus bus, {double latitude = 25.0005}) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    bus.frames.add([
      for (final (index, uid) in ['A', 'B', 'C', 'D'].indexed)
        BusStopEtaViewModel(
          stopUid: uid,
          direction: 0,
          sequence: index + 1,
          estimateSeconds: index == 0 ? -1 : index * 60,
          nextBusTime: index == 0 ? '23:59' : '',
          stopStatus: index == 0 ? 1 : 0,
          vehiclePlates: const ['BUS-1', 'BUS-2'],
          plate: index == 0 ? '' : 'BUS-1',
          vehicles: index == 1
              ? [
                  BusVehiclePosition(
                    plate: 'BUS-1',
                    lat: latitude,
                    lon: 121.0005,
                    azimuth: 45,
                    gpsTimeUnix: now,
                  ),
                  BusVehiclePosition(
                    plate: 'BUS-2',
                    lat: 25.002,
                    lon: 121.002,
                    azimuth: 0,
                    gpsTimeUnix: now,
                    busStatus: 3,
                  ),
                ]
              : const [],
        ),
    ]);
  }

  Marker visibleMarker(WidgetTester tester, String id) => tester
      .widget<GoogleMap>(find.byType(GoogleMap))
      .markers
      .firstWhere((marker) => marker.markerId.value == id);

  for (final unnamed in [false, true]) {
    testWidgets(
      'return-only routes open on their one actual direction ($unnamed)',
      (tester) async {
        await pump(tester, _Bus(returnOnly: true, missingEndpoints: unnamed));
        expect(find.byType(AppStaticSegment), findsOneWidget);
        expect(find.text('Return start'), findsWidgets);
        expect(find.text('Return end'), findsWidgets);
        expect(find.text('Start'), findsNothing);
        expect(
          tester
              .widget<GoogleMap>(find.byType(GoogleMap))
              .markers
              .map((marker) => marker.markerId.value),
          containsAll(['A', 'D']),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('buffer stop and second section remain visible in the route', (
    tester,
  ) async {
    final bus = _Bus(sectionFare: true);
    await pump(tester, bus);
    sendVehicles(bus);
    await flushLive(tester);
    await tester.drag(find.byType(SheetDragHandle), const Offset(0, -500));
    await flushLive(tester);
    final boundary = lookupAppI18n(
      const Locale('zh'),
    ).busSecondSectionFrom('End');
    await tester.ensureVisible(find.text(boundary));
    await flushLive(tester);
    expect(find.text(boundary), findsOneWidget);
    expect(find.text('Buffer'), findsWidgets);
    await tester.binding.handlePopRoute();
    await flushLive(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a fresh nearby GPS fix opens on its stop without a second pan', (
    tester,
  ) async {
    location.cached = Position(
      latitude: 25.001,
      longitude: 121.001,
      timestamp: DateTime.now().toUtc(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
    await pump(tester, _Bus());
    await flushLive(tester);
    expect(
      map.cameraUpdates.last.toJson(),
      CameraUpdate.newLatLngZoom(const LatLng(25.001, 121.001), 16).toJson(),
    );
    expect(map.cameraUpdates, hasLength(1));
    expect(find.text('Middle'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final reduced in [false, true]) {
    testWidgets('vehicle and stop map selections toggle (reduced=$reduced)', (
      tester,
    ) async {
      final bus = _Bus();
      await pump(tester, bus, reduced: reduced);
      sendVehicles(bus);
      await flushLive(tester);
      expect(visibleMarker(tester, 'bus:BUS-1').position.latitude, 25.0005);
      visibleMarker(tester, 'bus:BUS-1').onTap!();
      await flushLive(tester);
      expect(visibleMarker(tester, 'bus:BUS-2').alpha, 0.35);
      expect(visibleMarker(tester, 'bubble:BUS-1').position.latitude, 25.0005);
      visibleMarker(tester, 'bus:BUS-1').onTap!();
      await flushLive(tester);
      expect(visibleMarker(tester, 'bus:BUS-2').alpha, 1);
      final beforeStop = map.cameraUpdates.length;
      visibleMarker(tester, 'A').onTap!();
      await flushLive(tester);
      expect(map.cameraUpdates.length, greaterThan(beforeStop));
      final selected = map.cameraUpdates.length;
      visibleMarker(tester, 'A').onTap!();
      await flushLive(tester);
      expect(map.cameraUpdates.length, selected);
      tester.widget<GoogleMap>(find.byType(GoogleMap)).onTap!(
        const LatLng(25, 121),
      );
      await flushLive(tester);
      await tester.tap(
        find.byWidgetPredicate(
          (widget) => widget is Pressable && widget.semanticLabel == '定位目前位置',
        ),
      );
      await flushLive(tester);
      expect(map.cameraUpdates.length, greaterThan(selected));
      sendVehicles(bus, latitude: 25.001);
      await flushLive(tester);
      expect(visibleMarker(tester, 'bus:BUS-1').position.latitude, 25.001);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(map.disposed, map.created);
    });
  }

  Future<void> swipeVehicle(WidgetTester tester) async {
    await tester.drag(find.byType(SheetDragHandle), const Offset(0, -450));
    await flushLive(tester);
    final row = find.byType(AlightSwipeRow).first;
    await tester.ensureVisible(row);
    await flushLive(tester);
    await tester.drag(row, const Offset(400, 0));
    await flushLive(tester);
    expect(find.byType(AlightPickCapsule), findsOneWidget);
  }

  testWidgets(
    'closing a vehicle swipe leaves the journey idle and selectable',
    (
      tester,
    ) async {
      final journey = JourneySessionBloc(
        etaStream: (_) => const Stream.empty(),
        routeEtaStream: (_) => const Stream.empty(),
        liveActivityEnabled: () => true,
      );
      final bus = _Bus();
      await pump(tester, bus, journey: journey, reduced: true);
      sendVehicles(bus);
      await flushLive(tester);
      await swipeVehicle(tester);
      expect(journey.state.phase, JourneyPhase.idle);
      await tester.tap(
        find.descendant(
          of: find.byType(AlightPickCapsule),
          matching: find.byWidgetPredicate(
            (widget) => widget is Pressable && widget.semanticLabel == '關閉',
          ),
        ),
      );
      await flushLive(tester);
      expect(find.byType(AlightPickCapsule), findsNothing);
      expect(find.byType(AlightConfirmBar), findsNothing);
      expect(journey.state.phase, JourneyPhase.idle);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'vehicle swipe confirms the chosen stop and lead on the journey',
    (
      tester,
    ) async {
      final journey = JourneySessionBloc(
        etaStream: (_) => const Stream.empty(),
        routeEtaStream: (_) => const Stream.empty(),
        liveActivityEnabled: () => true,
      );
      final bus = _Bus();
      await pump(tester, bus, journey: journey);
      sendVehicles(bus);
      await flushLive(tester);
      await swipeVehicle(tester);
      final end = find.text('End').last;
      await tester.ensureVisible(end);
      await flushLive(tester);
      await tester.tap(end);
      await flushLive(tester);
      expect(find.byType(AlightConfirmBar), findsOneWidget);
      expect(find.text('下車站 End'), findsOneWidget);
      final increase = find.descendant(
        of: find.byType(AlightConfirmBar),
        matching: find.byIcon(Icons.add_rounded),
      );
      await tester.tap(increase);
      await tester.pump();
      await tester.tap(increase);
      await tester.pump();
      await tester.tap(find.text('開始追蹤'));
      await flushLive(tester);
      expect(journey.state.phase, JourneyPhase.waiting);
      expect(journey.state.trackOnly, true);
      expect(journey.state.plate, 'BUS-1');
      expect(journey.state.leadStops, 2);
      expect(journey.state.currentLeg!.boardStop, 'Middle');
      expect(journey.state.currentLeg!.alightStop, 'End');
      expect(find.byType(AlightConfirmBar), findsNothing);
      await tester.drag(find.byType(SheetDragHandle), const Offset(0, -500));
      await flushLive(tester);
      expect(
        find.byIcon(Icons.airline_seat_recline_extra_rounded),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  Future<void> showInformation(WidgetTester tester) async {
    await tester.drag(find.byType(SheetDragHandle), const Offset(0, -450));
    await tester.pumpAndSettle();
    await tester.tap(find.text('詳細資訊'));
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  List<Map<Object?, Object?>> captureLaunches({bool rejectInApp = false}) {
    final calls = <Map<Object?, Object?>>[];
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'launch') return true;
          final arguments = Map<Object?, Object?>.from(call.arguments as Map);
          calls.add(arguments);
          if (rejectInApp && arguments['useSafariVC'] == true) {
            throw PlatformException(code: 'unsupported');
          }
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    return calls;
  }

  testWidgets('route information exposes unknown data without invented trips', (
    tester,
  ) async {
    await pump(tester, _Bus());
    await showInformation(tester);
    expect(find.text('Start'), findsWidgets);
    expect(find.text('End'), findsWidgets);
    expect(find.text('→'), findsWidgets);
    expect(find.text('今日尚無發車資料'), findsOneWidget);
    await reveal(tester, find.text('尚無班表資料'));
    expect(find.text('尚無班表資料'), findsOneWidget);
    expect(find.byType(AppAccordion), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'blank endpoint metadata falls back to the direction stop names',
    (
      tester,
    ) async {
      await pump(tester, _Bus(missingEndpoints: true));
      await showInformation(tester);
      expect(find.text('Start'), findsWidgets);
      expect(find.text('End'), findsWidgets);
      expect(find.text('→'), findsWidgets);
      expect(find.text('-'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('an empty route keeps unknown endpoints and omits map markers', (
    tester,
  ) async {
    await pump(tester, _Bus(missingEndpoints: true, emptyStops: true));
    await showInformation(tester);
    expect(find.text('-'), findsWidgets);
    expect(find.text('Start'), findsNothing);
    expect(find.text('End'), findsNothing);
    expect(map.objects.markers, isEmpty);
    expect(map.markerUpdates.expand((update) => update.markersToAdd), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('route information preserves fare classes and weekly service', (
    tester,
  ) async {
    final launches = captureLaunches();
    await pump(tester, _Bus(details: true));
    await showInformation(tester);
    expect(find.text('Test operator'), findsOneWidget);
    await reveal(tester, find.byIcon(Icons.phone_outlined));
    await tester.tap(find.byIcon(Icons.phone_outlined));
    await tester.pump();
    expect(launches.last['url'], 'tel:0229992020');
    await tester.tap(find.byIcon(Icons.language_outlined));
    await tester.pump();
    expect(launches.last['url'], 'https://operator.example/route');
    expect(launches.last['useSafariVC'], true);
    await reveal(tester, find.text('全部票種（2 種）'));
    await tester.tap(find.text('全部票種（2 種）'));
    await tester.pumpAndSettle();
    expect(find.text(r'NT$8'), findsWidgets);
    expect(find.text(r'NT$15'), findsWidgets);
    final days = find.byWidgetPredicate(
      (widget) =>
          widget is AppSlidingSegment<int> && widget.options.length == 7,
    );
    await reveal(tester, days);
    final segment = tester.widget<AppSlidingSegment<int>>(days);
    final nonRunning = DateTime.now().weekday == DateTime.sunday ? 5 : 6;
    expect(segment.muted, contains(nonRunning));
    await tester.tap(
      find.descendant(
        of: days,
        matching: find.text(segment.options[nonRunning]!),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('本日未行駛'), findsOneWidget);
    await tester.tap(find.descendant(of: days, matching: find.text('一')));
    await tester.pumpAndSettle();
    expect(find.text('06:00–22:00'), findsOneWidget);
    expect(find.text('00:00'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('operator website falls back when the in-app browser fails', (
    tester,
  ) async {
    final launches = captureLaunches(rejectInApp: true);
    await pump(tester, _Bus(details: true));
    await showInformation(tester);
    await reveal(tester, find.byIcon(Icons.language_outlined));
    await tester.tap(find.byIcon(Icons.language_outlined));
    await tester.pump();
    expect(launches, hasLength(2));
    expect(launches.map((call) => call['useSafariVC']), [true, false]);
    expect(launches.last['url'], 'https://operator.example/route');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('upcoming trips stay bounded while the full timetable remains', (
    tester,
  ) async {
    await pump(tester, _Bus(details: true, manyTrips: true));
    await showInformation(tester);
    // Separate trips can share a clock time; the strip previews twelve,
    // while all twenty stay available on the timetable board below it.
    expect(find.text('23:59'), findsNWidgets(32));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('custom operator links use the external handler directly', (
    tester,
  ) async {
    final launches = captureLaunches();
    await pump(
      tester,
      _Bus(details: true, operatorUrl: 'custom://operator/route'),
    );
    await showInformation(tester);
    await reveal(tester, find.byIcon(Icons.language_outlined));
    await tester.tap(find.byIcon(Icons.language_outlined));
    await tester.pump();
    expect(launches, hasLength(1));
    expect(launches.single['url'], 'custom://operator/route');
    expect(launches.single['useSafariVC'], false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'invalid operator contact data does not launch a native handler',
    (
      tester,
    ) async {
      final launches = captureLaunches();
      await pump(
        tester,
        _Bus(
          details: true,
          operatorUrl: 'https://[',
          operatorPhone: 'unavailable',
        ),
      );
      await showInformation(tester);
      await reveal(tester, find.byIcon(Icons.language_outlined));
      await tester.tap(find.byIcon(Icons.language_outlined));
      await tester.tap(find.byIcon(Icons.phone_outlined));
      await tester.pump();
      expect(launches, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('OD fare search distinguishes origins, destinations and misses', (
    tester,
  ) async {
    await pump(tester, _Bus(details: true, odFares: true));
    await showInformation(tester);
    expect(find.text('依起訖站計費'), findsOneWidget);
    await reveal(tester, find.text('完整起迄票價（3 筆）'));
    await tester.tap(find.text('完整起迄票價（3 筆）'));
    await tester.pumpAndSettle();
    expect(find.text('Central'), findsOneWidget);
    expect(find.text('Harbor'), findsOneWidget);
    expect(find.text('Park'), findsOneWidget);
    final search = find.byType(TextField);
    await reveal(tester, search);
    await tester.enterText(search, 'Park');
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == 'Park',
      ),
      findsOneWidget,
    );
    expect(find.text('Harbor'), findsNothing);
    await tester.enterText(search, 'Central');
    await tester.pumpAndSettle();
    expect(find.text('Harbor'), findsOneWidget);
    await tester.enterText(search, 'nowhere');
    await tester.pumpAndSettle();
    expect(find.textContaining('nowhere'), findsWidgets);
    expect(find.text('Harbor'), findsNothing);
    expect(find.text('Central'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'OD table caps the initial rows but search reaches omitted fares',
    (
      tester,
    ) async {
      await pump(
        tester,
        _Bus(details: true, odFares: true, overflowFares: true),
      );
      await showInformation(tester);
      await reveal(tester, find.text('完整起迄票價（82 筆）'));
      await tester.tap(find.text('完整起迄票價（82 筆）'));
      await tester.pumpAndSettle();
      expect(find.text('Stop-79'), findsOneWidget);
      expect(find.text('Stop-80'), findsNothing);
      expect(find.text('Last destination'), findsNothing);
      expect(find.text('Second origin'), findsNothing);
      expect(find.text('僅顯示前 80 筆，輸入站牌以查詢其餘起訖票價'), findsOneWidget);
      final search = find.byType(TextField);
      await reveal(tester, search);
      await tester.enterText(search, 'Stop-80');
      await tester.pumpAndSettle();
      expect(find.text('Stop-80'), findsWidgets);
      expect(find.text('Stop-79'), findsNothing);
      expect(find.textContaining('僅顯示前 80 筆'), findsNothing);
      await tester.enterText(search, 'Second origin');
      await tester.pumpAndSettle();
      expect(find.text('Last destination'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'route opens with stops and selecting return '
    'changes both timeline and list',
    (tester) async {
      final bus = _Bus();
      await pump(tester, bus);
      expect(find.text('307'), findsWidgets);
      expect(map.created, hasLength(1));
      expect(
        [
          ...map.objects.markers,
          ...map.markerUpdates.expand((update) => update.markersToAdd),
        ],
        isNotEmpty,
      );
      expect(map.cameraUpdates, isNotEmpty);
      expect(find.text('Start'), findsWidgets);
      expect(find.text('Middle'), findsWidgets);
      expect(find.text('往 End'), findsWidgets);
      await tester.tap(
        find.descendant(
          of: find.byType(AppSlidingSegment<int>),
          matching: find.text('往 Start'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Return start'), findsWidgets);
      expect(find.text('往 Start'), findsWidgets);
      await tester.drag(find.byType(SheetDragHandle), const Offset(0, -450));
      await tester.pumpAndSettle();
      expect(find.text('站牌列表'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(map.disposed, map.created);
    },
  );

  testWidgets('failed route loading exposes retry without a fabricated stop', (
    tester,
  ) async {
    final bus = _Bus(fail: true);
    await pump(tester, bus);
    await tester.drag(find.byType(SheetDragHandle), const Offset(0, -450));
    await tester.pumpAndSettle();
    expect(find.text('Middle'), findsNothing);
    expect(bus.loads, 1);
    bus.fail = false;
    final tabs = tester.widget<TabBarView>(find.byType(TabBarView));
    final retry = find.descendant(
      of: find.byWidget(tabs.children[tabs.controller!.index]),
      matching: find.byWidgetPredicate(
        (widget) => widget is Pressable && widget.semanticLabel == '重試',
      ),
    );
    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();
    await tester.tap(retry);
    await flushLive(tester);
    expect(bus.loads, 2);
    expect(find.text('Middle'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  Finder underSheet(bool Function(Widget) test) => find.descendant(
    of: find.byType(AppSheet),
    matching: find.byWidgetPredicate(test),
  );

  Finder identityRow() => underSheet((w) => w is Opacity && w.child is Padding);

  testWidgets('sheet content cross-fades with the drag progress', (
    tester,
  ) async {
    await pump(tester, _Bus(), reduced: true);
    Opacity? fader({required bool tabs}) {
      final found = tester
          .widgetList<Opacity>(
            underSheet((w) => w is Opacity && w.child is IgnorePointer),
          )
          .where(
            (o) => ((o.child! as IgnorePointer).child is Column) == tabs,
          );
      return found.isEmpty ? null : found.single;
    }

    // At peek: timeline fully opaque and live, no tabs, no identity strip.
    expect(fader(tabs: true), isNull);
    expect(fader(tabs: false)!.opacity, 1);
    expect((fader(tabs: false)!.child! as IgnorePointer).ignoring, isFalse);
    expect(identityRow(), findsNothing);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(SheetDragHandle)),
    );
    final regions = <String>{};
    for (var step = 0; step < 30; step++) {
      await gesture.moveBy(const Offset(0, -16));
      await tester.pump(const Duration(milliseconds: 16));
      final timeline = fader(tabs: false);
      final tabs = fader(tabs: true);
      final tl = timeline?.opacity;
      final tb = tabs?.opacity;
      final double? p;
      if (tl != null && tl > 0 && tl < 1) {
        p = (1 - tl) / 1.6;
      } else if (tb != null && tb > 0 && tb < 1) {
        p = tb / 1.6 + 0.25;
      } else {
        p = null;
      }
      if (tl != null && tl > 0 && tl < 1 && tb != null && tb > 0 && tb < 1) {
        // Where both fade at once the two ramps must agree on the progress.
        expect(tb, closeTo((p! - 0.25) * 1.6, 1e-9));
        regions.add('overlap');
      }
      if (p == null) continue;
      expect(tabs != null, p > 0.25, reason: 'tabs presence at $p');
      expect(timeline != null, p < 0.75, reason: 'timeline presence at $p');
      if (timeline != null) {
        expect(
          (timeline.child! as IgnorePointer).ignoring,
          p > 0.5,
          reason: 'timeline ignoring at $p',
        );
      }
      if (tabs != null) {
        expect(
          (tabs.child! as IgnorePointer).ignoring,
          p < 0.5,
          reason: 'tabs ignoring at $p',
        );
      }
      final identity = ((p - 0.6) / 0.4).clamp(0.0, 1.0);
      if (identity > 0) {
        expect(
          tester.widget<Opacity>(identityRow()).opacity,
          closeTo(identity, 1e-9),
          reason: 'identity at $p',
        );
        regions.add('identity');
      } else {
        expect(identityRow(), findsNothing, reason: 'identity at $p');
      }
      regions.add(
        p < 0.25
            ? 'early'
            : p < 0.5
            ? 'lower-mid'
            : p < 0.625
            ? 'upper-mid'
            : 'late',
      );
    }
    await gesture.up();
    expect(
      regions,
      containsAll(['early', 'lower-mid', 'upper-mid', 'overlap']),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final direction in [0, 1]) {
    testWidgets('the identity strip names direction $direction', (
      tester,
    ) async {
      await pump(tester, _Bus(), reduced: true);
      final segment = find.byType(AppSlidingSegment<int>);
      if (direction == 1) {
        await tester.tap(
          find.descendant(of: segment, matching: find.text('往 Start')),
        );
        await tester.pumpAndSettle();
      }
      await tester.drag(find.byType(SheetDragHandle), const Offset(0, -500));
      await tester.pumpAndSettle();

      final strip = identityRow();
      expect(
        find.descendant(of: strip, matching: find.text('307')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: strip,
          matching: find.text(direction == 0 ? '往 End' : '往 Start'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: strip,
          matching: find.text(direction == 0 ? '往 Start' : '往 End'),
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('unnamed directions fall back to outbound then inbound', (
    tester,
  ) async {
    await pump(tester, _Bus(missingEndpoints: true), reduced: true);
    final i18n = lookupAppI18n(const Locale('zh'));
    final segment = find.byType(AppSlidingSegment<int>);

    final outbound = find.descendant(
      of: segment,
      matching: find.text(i18n.busDirectionOutbound),
    );
    final inbound = find.descendant(
      of: segment,
      matching: find.text(i18n.busDirectionInbound),
    );
    expect(
      tester.getTopLeft(outbound).dx,
      lessThan(tester.getTopLeft(inbound).dx),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final dark in [false, true]) {
    testWidgets('route pill surface (dark=$dark)', (tester) async {
      await pump(tester, _Bus(), reduced: dark);
      final cs = (dark ? AppTheme.dark : AppTheme.light).colorScheme;

      final pill = tester.widget<Container>(
        find
            .ancestor(
              of: find.descendant(
                of: find.byType(FloatingAppBar),
                matching: find.text('307'),
              ),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = pill.decoration! as BoxDecoration;
      expect(decoration.color, dark ? cs.surfaceContainerHigh : Colors.white);
      expect(decoration.borderRadius, BorderRadius.circular(12));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final toDirection in [1, 0]) {
    testWidgets('the pill slides the headsign toward direction $toDirection', (
      tester,
    ) async {
      await pump(tester, _Bus());
      final segment = find.byType(AppSlidingSegment<int>);
      if (toDirection == 0) {
        await tester.tap(
          find.descendant(of: segment, matching: find.text('往 Start')),
        );
        await tester.pumpAndSettle();
      }
      final incomingName = toDirection == 1 ? '往 Start' : '往 End';
      final outgoingName = toDirection == 1 ? '往 End' : '往 Start';
      await tester.tap(
        find.descendant(of: segment, matching: find.text(incomingName)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      double slideOf(String name) {
        final slide = find.ancestor(
          of: find.descendant(
            of: find.byType(FloatingAppBar),
            matching: find.text(name),
          ),
          matching: find.byType(SlideTransition),
        );
        return tester.widget<SlideTransition>(slide.first).position.value.dy;
      }

      // The incoming child is built while its animation is still dismissed and
      // the outgoing one is rebuilt while completed, so the two start on
      // opposite sides and travel the same way.
      final sign = toDirection == 1 ? 1 : -1;
      expect(slideOf(incomingName) * sign, lessThan(0));
      expect(slideOf(outgoingName) * sign, greaterThan(0));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('an unknown origin and destination both read as a dash', (
    tester,
  ) async {
    await pump(tester, _Bus(missingEndpoints: true, emptyStops: true));
    await showInformation(tester);

    expect(find.text('-'), findsNWidgets(2));
    expect(find.text('+'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an unknown operating city reads as a dash', (tester) async {
    await pump(tester, _Bus(emptyCity: true));
    await showInformation(tester);

    expect(find.text('-'), findsOneWidget);
    expect(find.text('+'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an unnamed operator reads as a dash', (tester) async {
    await pump(tester, _Bus(details: true));
    await showInformation(tester);
    await reveal(tester, find.text('Test operator'));

    expect(find.text('-'), findsOneWidget);
    expect(find.text('+'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('endpoints stack only once they no longer fit on one line', (
    tester,
  ) async {
    Future<double> columnWidth() async {
      final i18n = lookupAppI18n(const Locale('zh'));
      return tester
          .getSize(
            find
                .ancestor(
                  of: find.text(i18n.busEndpoints),
                  matching: find.byType(Column),
                )
                .first,
          )
          .width;
    }

    double needed(String a, String b) {
      double widthOf(String text) => (TextPainter(
        text: TextSpan(text: text, style: AppTextStyles.bodyLarge),
        textDirection: TextDirection.ltr,
      )..layout()).width;
      return widthOf(a) + widthOf('→') + widthOf(b) + 8;
    }

    Future<void> mount(double width, String a, String b) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      await pump(tester, _Bus(startName: a, endName: b), reduced: true);
      await showInformation(tester);
    }

    addTearDown(tester.view.reset);
    await mount(800, 'M' * 10, 'M' * 2);
    final gutter = 800 - 2 * await columnWidth();
    await tester.pumpWidget(const SizedBox.shrink());

    // Exactly as wide as the half-width column: still one line.
    final exact = needed('M' * 10, 'M' * 2);
    await mount(2 * exact + gutter, 'M' * 10, 'M' * 2);
    expect(await columnWidth(), closeTo(exact, 1e-6));
    expect(find.text('→'), findsOneWidget);
    expect(find.text('↓'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());

    // One more glyph overflows by less than the 8px slack and the arrow, so
    // only the true measurement can tell the two layouts apart.
    await mount(2 * exact + gutter, 'M' * 11, 'M' * 2);
    expect(find.text('↓'), findsOneWidget);
    expect(find.text('→'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<void> openOdFares(WidgetTester tester, int count) async {
    final title = find.text('完整起迄票價（$count 筆）');
    await reveal(tester, title);
    await tester.tap(title);
    await tester.pumpAndSettle();
  }

  testWidgets('the OD cap is shared across origins, not reset per origin', (
    tester,
  ) async {
    await pump(
      tester,
      _Bus(
        details: true,
        odFares: true,
        odPlan: const [('OA', 30), ('OB', 30), ('OC', 30)],
      ),
    );
    await showInformation(tester);
    await openOdFares(tester, 90);

    expect(find.text('OB-29'), findsOneWidget);
    expect(find.text('OC-19'), findsOneWidget);
    expect(find.text('OC-20'), findsNothing);
    expect(find.text('僅顯示前 80 筆，輸入站牌以查詢其餘起訖票價'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a full table drops the next origin entirely', (tester) async {
    await pump(
      tester,
      _Bus(
        details: true,
        odFares: true,
        odPlan: const [('OA', 80), ('OB', 1)],
      ),
    );
    await showInformation(tester);
    await openOdFares(tester, 81);

    expect(find.text('OA-79'), findsOneWidget);
    expect(find.text('OB'), findsNothing);
    expect(find.text('僅顯示前 80 筆，輸入站牌以查詢其餘起訖票價'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a table that fits shows no truncation note', (tester) async {
    await pump(
      tester,
      _Bus(
        details: true,
        odFares: true,
        odPlan: const [('OA', 40), ('OB', 40)],
      ),
    );
    await showInformation(tester);
    await openOdFares(tester, 80);

    expect(find.text('OB-39'), findsOneWidget);
    expect(find.textContaining('僅顯示前 80 筆'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a varying OD price is summarised as a range', (tester) async {
    await pump(
      tester,
      _Bus(details: true, odFares: true, odPlan: const [('OA', 3)]),
    );
    await showInformation(tester);
    final i18n = lookupAppI18n(const Locale('zh'));

    expect(find.text(i18n.busFareByOd), findsOneWidget);
    expect(find.text(i18n.busFareFlat), findsNothing);
    expect(find.text(i18n.busFareRange(i18n.fareFull)), findsOneWidget);
    expect(find.text(r'NT$20 – NT$22'), findsOneWidget);
    expect(find.text(i18n.busAllFareClasses(1)), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a uniform OD price is one amount, not a range', (tester) async {
    await pump(
      tester,
      _Bus(
        details: true,
        odFares: true,
        odPlan: const [('OA', 3)],
        odFlatPrice: true,
      ),
    );
    await showInformation(tester);
    final i18n = lookupAppI18n(const Locale('zh'));

    expect(find.text(i18n.busFareFlat), findsOneWidget);
    expect(find.text(i18n.busFareByOd), findsNothing);
    expect(find.text(i18n.busFareRange(i18n.fareFull)), findsOneWidget);
    expect(find.text(r'NT$20'), findsOneWidget);
    expect(find.textContaining(r'NT$20 –'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an OD route has no flat fare list to disclose', (tester) async {
    await pump(tester, _Bus(details: true, odFares: true));
    await showInformation(tester);
    final i18n = lookupAppI18n(const Locale('zh'));

    // Two classes are priced, but only inside the OD table.
    expect(find.text(i18n.busAllOdFares(3)), findsOneWidget);
    expect(find.textContaining('全部票種'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a flat route with several classes offers their disclosure', (
    tester,
  ) async {
    await pump(tester, _Bus(details: true));
    await showInformation(tester);
    final i18n = lookupAppI18n(const Locale('zh'));

    expect(find.text(i18n.busAllFareClasses(2)), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  Future<void> setFareType(WidgetTester tester, FareType type) =>
      tester.runAsync(() async {
        SettingsRepository.instance.fareType = type;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

  testWidgets('an OD row states only its price when the class matches', (
    tester,
  ) async {
    await pump(
      tester,
      _Bus(details: true, odFares: true, odPlan: const [('OA', 3)]),
    );
    await showInformation(tester);
    await openOdFares(tester, 3);

    for (final price in [r'NT$20', r'NT$21', r'NT$22']) {
      expect(find.text(price), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an OD row names the class it fell back to', (tester) async {
    await setFareType(tester, FareType.concession);
    addTearDown(() => SettingsRepository.instance.fareType = FareType.full);
    await pump(
      tester,
      _Bus(details: true, odFares: true, odPlan: const [('OA', 3)]),
    );
    await showInformation(tester);
    await openOdFares(tester, 3);

    final labelled = find.byWidgetPredicate(
      (w) =>
          w is Text &&
          (w.data ?? '').endsWith(r'NT$20') &&
          (w.data ?? '') != r'NT$20',
    );
    expect(labelled, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a flat fare quotes the class label when it matches', (
    tester,
  ) async {
    await pump(tester, _Bus(details: true));
    await showInformation(tester);

    expect(find.textContaining('（無'), findsNothing);
    expect(find.text(r'NT$15'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a flat fare admits when the rider class is not priced', (
    tester,
  ) async {
    await setFareType(tester, FareType.concession);
    addTearDown(() => SettingsRepository.instance.fareType = FareType.full);
    await pump(tester, _Bus(details: true, onlyFullFare: true));
    await showInformation(tester);
    final i18n = lookupAppI18n(const Locale('zh'));

    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data ?? '').endsWith('（無${FareType.concession.labelOf(i18n)}）'),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a route with no stops opens on the default camera', (
    tester,
  ) async {
    await pump(tester, _Bus(missingEndpoints: true, emptyStops: true));

    final camera = tester
        .widget<GoogleMap>(find.byType(GoogleMap))
        .initialCameraPosition;
    expect(camera.target, const LatLng(25.0416, 121.5501));
    expect(camera.zoom, 14);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a one-stop route fits by zooming on it', (tester) async {
    await pump(tester, _Bus(singleStop: true));

    expect(
      map.cameraUpdates.first.toJson(),
      CameraUpdate.newLatLngZoom(const LatLng(25, 121), 16).toJson(),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a longer route fits the bounds of all its stops', (
    tester,
  ) async {
    await pump(tester, _Bus());

    expect(
      map.cameraUpdates.first.toJson(),
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: const LatLng(25, 121),
          northeast: const LatLng(25.003, 121.003),
        ),
        60,
      ).toJson(),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tapping a stop marker aims at that stop, tapping again does '
      'not move', (tester) async {
    await pump(tester, _Bus());
    final before = map.cameraUpdates.length;

    visibleMarker(tester, 'C').onTap!();
    await flushLive(tester);

    expect(map.cameraUpdates.length, before + 1);
    expect(
      map.cameraUpdates.last.toJson(),
      CameraUpdate.newLatLngZoom(const LatLng(25.002, 121.002), 16).toJson(),
    );
    visibleMarker(tester, 'C').onTap!();
    await flushLive(tester);
    expect(map.cameraUpdates.length, before + 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a tapped stop stays flashed for 2.5s and a new tap restarts '
      'the clock', (tester) async {
    await pump(tester, _Bus());
    String? flashed() => tester
        .widget<HorizontalRouteTimeline>(find.byType(HorizontalRouteTimeline))
        .flashStopUid;

    visibleMarker(tester, 'B').onTap!();
    await tester.pump(const Duration(milliseconds: 1500));
    expect(flashed(), 'B');
    visibleMarker(tester, 'C').onTap!();
    await tester.pump(const Duration(milliseconds: 1500));
    // 3s after B, but only 1.5s after C: B's timer must not clear C's flash.
    expect(flashed(), 'C');
    await tester.pump(const Duration(milliseconds: 1100));
    expect(flashed(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a stop tap centres its cell in the timeline strip', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pump(tester, _Bus());
    double offset() => tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(HorizontalRouteTimeline),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .pixels;

    visibleMarker(tester, 'C').onTap!();
    await flushLive(tester);

    // Cell 2's dot is at 2*120+60 of content, plus 20 of padding, centred in
    // a 360 viewport: 300 + 20 - 180.
    expect(offset(), closeTo(140, 0.5));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('locate button', () {
    Positioned anchor(WidgetTester tester) => tester.widget<Positioned>(
      find
          .ancestor(
            of: find.byIcon(Icons.gps_fixed_rounded),
            matching: find.byType(Positioned),
          )
          .first,
    );

    double sheetOffset(WidgetTester tester) =>
        tester.widget<AppSheet>(find.byType(AppSheet)).controller!.value!;

    for (final dark in [false, true]) {
      testWidgets('styling (dark=$dark)', (tester) async {
        await pump(tester, _Bus(), reduced: dark);
        final cs = (dark ? AppTheme.dark : AppTheme.light).colorScheme;

        final box = tester.widget<Container>(
          find
              .ancestor(
                of: find.byIcon(Icons.gps_fixed_rounded),
                matching: find.byType(Container),
              )
              .first,
        );
        final decoration = box.decoration! as BoxDecoration;
        expect(decoration.color, dark ? cs.surfaceContainerHigh : Colors.white);
        expect(decoration.borderRadius, BorderRadius.circular(12));
        expect(anchor(tester).right, 16);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('rides the sheet to peek then fades over eighty pixels', (
      tester,
    ) async {
      await pump(tester, _Bus());
      const peek = 150.0;
      expect(sheetOffset(tester), closeTo(peek, 0.5));
      expect(anchor(tester).bottom, closeTo(peek + 16, 0.5));

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(SheetDragHandle)),
      );
      final seen = <String>{};
      for (var step = 0; step < 14; step++) {
        await gesture.moveBy(const Offset(0, -12));
        await tester.pump(const Duration(milliseconds: 16));
        final offset = sheetOffset(tester);
        final over = offset - peek;
        final opacity = tester
            .widget<Opacity>(
              find
                  .ancestor(
                    of: find.byIcon(Icons.gps_fixed_rounded),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity;
        final ignoring = tester
            .widget<IgnorePointer>(
              find
                  .ancestor(
                    of: find.byIcon(Icons.gps_fixed_rounded),
                    matching: find.byType(IgnorePointer),
                  )
                  .first,
            )
            .ignoring;
        expect(opacity, closeTo((1 - over / 80).clamp(0.0, 1.0), 1e-6));
        expect(ignoring, opacity == 0);
        expect(
          anchor(tester).bottom,
          closeTo(offset.clamp(0.0, peek) + 16, 0.5),
        );
        seen.add(
          opacity == 1
              ? 'rest'
              : opacity == 0
              ? 'gone'
              : 'fading',
        );
      }
      await gesture.up();
      expect(seen, containsAll(['fading', 'gone']));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('a theme or text-size change repaints the map layer', (
    tester,
  ) async {
    final bus = _Bus();
    await pump(tester, bus);
    await flushLive(tester);
    final base = map.markerUpdates.length;

    await pump(tester, bus, textScale: 1.3);
    await flushLive(tester);
    final scaled = map.markerUpdates.length;
    expect(scaled, greaterThan(base));

    await pump(tester, bus, textScale: 1.3, dark: true);
    await flushLive(tester);
    expect(map.markerUpdates.length, greaterThan(scaled));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

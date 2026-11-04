import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/data/repositories/places_repository.dart';
import 'package:wheres_the_bus/features/go/bloc/place_search_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/place_search_event.dart';
import 'package:wheres_the_bus/features/go/bloc/place_search_state.dart';
import 'package:wheres_the_bus/features/go/model/planned_place.dart';
import 'package:wheres_the_bus/features/go/view/place_search_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/app_button.dart';

class _Search extends PlaceSearchBloc {
  _Search(PlaceSearchState initial) {
    emit(initial);
  }
  final events = <PlaceSearchEvent>[];
  @override
  void add(PlaceSearchEvent event) => events.add(event);
  void show(PlaceSearchState next) => emit(next);
}

class _Location extends GeolocatorPlatform {
  bool enabled = true;
  Position? cached;
  final current = Position(
    latitude: 25,
    longitude: 121,
    timestamp: DateTime.utc(2030),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
  @override
  Future<bool> isLocationServiceEnabled() async => enabled;
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;
  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async => current;
  @override
  Future<Position?> getLastKnownPosition({
    bool forceLocationManager = false,
  }) async => cached;
}

const home = PlannedPlace(name: '住家', latLng: LatLng(25, 121), iconKey: 'home');
const recent = PlannedPlace(name: '車站', latLng: LatLng(24, 120));

void main() {
  late GeolocatorPlatform previous;
  late _Location location;
  setUp(() {
    previous = GeolocatorPlatform.instance;
    location = _Location();
    GeolocatorPlatform.instance = location;
    LocationService.denial.value = null;
  });
  tearDown(() {
    GeolocatorPlatform.instance = previous;
    LocationService.denial.value = null;
  });

  final picked = <PlannedPlace>[];
  var backs = 0;
  Future<_Search> show(
    WidgetTester tester,
    PlaceSearchState state, {
    bool hosted = false,
    bool allowLocation = true,
  }) async {
    picked.clear();
    backs = 0;
    tester.view.physicalSize = const Size(430, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bloc = _Search(state);
    addTearDown(bloc.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: Scaffold(
          body: PlaceSearchView(
            bloc: bloc,
            showInput: true,
            autofocus: true,
            allowCurrentLocation: allowLocation,
            fieldLabel: '目的地',
            emptyHint: '請選擇地點',
            header: const Text('header'),
            headerBuilder: hosted ? (_, input) => input : null,
            onBack: () => backs++,
            onPicked: picked.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(bloc.events.single, isA<PlaceSearchStarted>());
    return bloc;
  }

  void press(WidgetTester tester, String label) => tester
      .widget<Pressable>(
        find.byWidgetPredicate(
          (widget) => widget is Pressable && widget.semanticLabel == label,
        ),
      )
      .onTap!();

  Future<void> dispose(WidgetTester tester, _Search bloc) async {
    await tester.pumpWidget(const SizedBox.shrink());
    expect(bloc.isClosed, isFalse);
    expect(tester.takeException(), isNull);
  }

  testWidgets('typing, result selection and clearing keep bias and intents', (
    tester,
  ) async {
    location.cached = location.current;
    final bloc = await show(tester, const PlaceSearchState());
    expect(find.text('請選擇地點'), findsOneWidget);
    expect(find.byType(AppBarBackButton), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);
    press(tester, '返回');
    expect(backs, 1);
    await tester.enterText(find.byType(TextField), '車站');
    final query = bloc.events.last as PlaceQueryChanged;
    expect(query.query, '車站');
    expect(query.bias, const LatLng(25, 121));
    bloc.show(const PlaceSearchState(query: '車站', loading: true));
    await tester.pump();
    bloc.show(const PlaceSearchState(query: '車站'));
    await tester.pumpAndSettle();
    const suggestion = PlaceSuggestion(
      placeId: 'id',
      primaryText: '車站',
      secondaryText: '台北',
    );
    bloc.show(const PlaceSearchState(query: '車站', results: [suggestion]));
    await tester.pumpAndSettle();
    press(tester, '車站');
    expect(
      (bloc.events.last as PlaceResolveRequested).intent,
      ResolveIntent.pick,
    );
    final row = tester.widget<Dismissible>(find.byType(Dismissible));
    expect(await row.confirmDismiss!(DismissDirection.startToEnd), isFalse);
    expect(
      (bloc.events.last as PlaceResolveRequested).intent,
      ResolveIntent.save,
    );
    bloc.show(
      const PlaceSearchState(
        query: '車站',
        results: [suggestion],
        pickingId: 'id',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widgetList<Pressable>(find.byType(Pressable))
          .where((widget) => widget.semanticLabel == '車站')
          .single
          .onTap,
      isNull,
    );
    press(tester, '清除');
    expect((bloc.events.last as PlaceQueryChanged).query, '');
    await dispose(tester, bloc);
  });

  testWidgets('effects are consumed once and save dialogs retain chosen name', (
    tester,
  ) async {
    final bloc = await show(tester, const PlaceSearchState(), hosted: true);
    bloc.show(
      const PlaceSearchState(
        effect: PlaceSearchEffect(
          seq: 1,
          resolved: home,
          intent: ResolveIntent.pick,
        ),
      ),
    );
    await tester.pump();
    expect(picked.single, home);
    bloc.show(bloc.state.copyWith(query: 'changed'));
    await tester.pumpAndSettle();
    expect(picked, hasLength(1));
    bloc.show(
      const PlaceSearchState(
        effect: PlaceSearchEffect(seq: 2, error: PlaceSearchErrorKind.place),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('無法取得地點資訊'), findsOneWidget);
    bloc.show(
      const PlaceSearchState(
        effect: PlaceSearchEffect(seq: 3, error: PlaceSearchErrorKind.location),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('無法取得目前位置'), findsOneWidget);
    bloc.show(
      const PlaceSearchState(
        effect: PlaceSearchEffect(
          seq: 4,
          resolved: recent,
          intent: ResolveIntent.save,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '  公司  ');
    press(tester, 'work');
    tester.widget<AppButton>(find.widgetWithText(AppButton, '儲存')).onPressed!();
    await tester.pumpAndSettle();
    final saved = bloc.events.last as PlaceSaved;
    expect((saved.name, saved.iconKey), ('公司', 'work'));
    expect(find.text('已儲存地點'), findsOneWidget);
    await dispose(tester, bloc);
  });

  testWidgets('saved and recent shortcuts remove and undo their own entries', (
    tester,
  ) async {
    final bloc = await show(
      tester,
      const PlaceSearchState(saved: [home], recents: [recent]),
      allowLocation: false,
    );
    press(tester, '住家');
    expect(picked.single, home);
    final rows = tester
        .widgetList<Dismissible>(find.byType(Dismissible))
        .toList();
    expect(
      await rows.first.confirmDismiss!(DismissDirection.endToStart),
      isTrue,
    );
    rows.first.onDismissed!(DismissDirection.endToStart);
    await tester.pumpAndSettle();
    expect(bloc.events.last, isA<SavedRemoved>());
    press(tester, '復原');
    expect(bloc.events.last, isA<SavedRestored>());
    rows.last.onDismissed!(DismissDirection.endToStart);
    await tester.pumpAndSettle();
    expect(bloc.events.last, isA<RecentRemoved>());
    press(tester, '復原');
    expect(bloc.events.last, isA<RecentRestored>());
    await dispose(tester, bloc);
  });

  testWidgets(
    'saved-place editing keeps its identity and cancel has no write',
    (tester) async {
      final bloc = await show(tester, const PlaceSearchState(saved: [home]));
      final savedRow = tester.widget<Pressable>(
        find.byWidgetPredicate(
          (w) => w is Pressable && w.semanticLabel == '住家',
        ),
      );
      savedRow.onLongPress!();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        '住家',
      );
      await tester.enterText(find.byType(TextField).last, '新家');
      tester
          .widget<AppButton>(find.widgetWithText(AppButton, '儲存'))
          .onPressed!();
      await tester.pumpAndSettle();
      final saved = bloc.events.last as PlaceSaved;
      expect(saved.place, home);
      expect((saved.name, saved.iconKey), ('新家', 'home'));
      final before = bloc.events.length;
      savedRow.onLongPress!();
      await tester.pumpAndSettle();
      tester
          .widget<AppButton>(find.widgetWithText(AppButton, '取消'))
          .onPressed!();
      await tester.pumpAndSettle();
      expect(bloc.events.length, before);
      await dispose(tester, bloc);
    },
  );

  testWidgets(
    'location success, cached fallback and total failure are explicit',
    (tester) async {
      final bloc = await show(tester, const PlaceSearchState());
      press(tester, '使用目前位置');
      await tester.pumpAndSettle();
      expect(picked.single.latLng, const LatLng(25, 121));
      expect(picked.single.isCurrentLocation, isTrue);
      expect((bloc.events.last as LocationResolving).active, isFalse);
      picked.clear();
      location
        ..enabled = false
        ..cached = location.current;
      press(tester, '使用目前位置');
      await tester.pumpAndSettle();
      expect(picked, hasLength(1));
      picked.clear();
      location.cached = null;
      press(tester, '使用目前位置');
      await tester.pumpAndSettle();
      expect(picked, isEmpty);
      expect((bloc.events.last as LocationResolving).failed, isTrue);
      await dispose(tester, bloc);
    },
  );
}

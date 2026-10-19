import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  Future<bool> isLocationServiceEnabled() async => true;
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
  }) async => null;
}

const _home = PlannedPlace(
  name: '住家',
  latLng: LatLng(25, 121),
  iconKey: 'home',
);
const _recent = PlannedPlace(name: '車站', latLng: LatLng(24, 120));
const _suggestion = PlaceSuggestion(
  placeId: 'id',
  primaryText: '車站',
  secondaryText: '台北',
);

void main() {
  late GeolocatorPlatform previous;
  final haptics = <String>[];
  final i18n = lookupAppI18n(const Locale('zh'));
  setUp(() {
    previous = GeolocatorPlatform.instance;
    GeolocatorPlatform.instance = _Location();
    LocationService.denial.value = null;
    haptics.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add((call.arguments as String).split('.').last);
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    GeolocatorPlatform.instance = previous;
    LocationService.denial.value = null;
  });

  Future<_Search> show(
    WidgetTester tester,
    PlaceSearchState state, {
    bool hosted = false,
    bool showInput = true,
    bool autofocus = true,
    bool allowLocation = true,
    bool animating = false,
  }) async {
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
            showInput: showInput,
            autofocus: autofocus,
            allowCurrentLocation: allowLocation,
            fieldLabel: '目的地',
            emptyHint: '請選擇地點',
            headerBuilder: hosted ? (_, input) => input : null,
            onPicked: (_) {},
          ),
        ),
      ),
    );
    // Skeleton shimmer loops forever, so it can never settle.
    if (animating) {
      await tester.pump(const Duration(milliseconds: 500));
    } else {
      await tester.pumpAndSettle();
    }
    return bloc;
  }

  bool focused(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;

  testWidgets('the field is focused for a host-placed input or autofocus', (
    tester,
  ) async {
    await show(
      tester,
      const PlaceSearchState(),
      hosted: true,
      autofocus: false,
    );
    expect(focused(tester), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await show(tester, const PlaceSearchState());
    expect(focused(tester), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await show(tester, const PlaceSearchState(), autofocus: false);
    expect(focused(tester), isFalse);
  });

  testWidgets('using the current location announces the busy state first', (
    tester,
  ) async {
    final bloc = await show(tester, const PlaceSearchState());
    tester
        .widget<Pressable>(
          find.byWidgetPredicate(
            (w) =>
                w is Pressable && w.semanticLabel == i18n.goUseCurrentLocation,
          ),
        )
        .onTap!();
    await tester.pumpAndSettle();
    final resolving = bloc.events.whereType<LocationResolving>().toList();
    expect([for (final e in resolving) e.active], [true, false]);
  });

  testWidgets('the current-location row shows its glyph and label', (
    tester,
  ) async {
    await show(tester, const PlaceSearchState());
    expect(find.byIcon(Icons.my_location_rounded), findsOneWidget);
    expect(find.text(i18n.goCurrentLocation), findsOneWidget);
  });

  testWidgets('removing a recent or saved place taps lightly', (tester) async {
    await show(
      tester,
      const PlaceSearchState(saved: [_home], recents: [_recent]),
      allowLocation: false,
    );
    final rows = tester.widgetList<Dismissible>(find.byType(Dismissible));
    rows.first.onDismissed!(DismissDirection.endToStart);
    await tester.pumpAndSettle();
    expect(haptics, ['lightImpact']);
    rows.last.onDismissed!(DismissDirection.endToStart);
    await tester.pumpAndSettle();
    expect(haptics, ['lightImpact', 'lightImpact']);
  });

  testWidgets('shortcut rows swipe both ways under their own keys', (
    tester,
  ) async {
    await show(
      tester,
      const PlaceSearchState(saved: [_home], recents: [_recent]),
      allowLocation: false,
    );
    final rows = tester
        .widgetList<Dismissible>(find.byType(Dismissible))
        .toList();
    expect(rows.first.key, const ValueKey('dismiss-saved-住家-25.0-121.0'));
    expect(rows.last.key, const ValueKey('dismiss-recent-車站-24.0-120.0'));
    for (final row in rows) {
      expect(row.direction, DismissDirection.horizontal);
      expect(row.secondaryBackground, isNotNull);
      final save = row.background! as Container;
      final icon = (save.child! as Row).children.first as Icon;
      expect((icon.icon, icon.size), (Icons.bookmark_add_rounded, 22));
      final remove = (row.secondaryBackground! as Container).child! as Icon;
      expect(remove.size, 22);
    }
    expect(
      ((rows.first.secondaryBackground! as Container).child! as Icon).icon,
      Icons.bookmark_remove_rounded,
    );
    expect(
      ((rows.last.secondaryBackground! as Container).child! as Icon).icon,
      Icons.delete_rounded,
    );
  });

  testWidgets('result rows only swipe right to save', (tester) async {
    await show(
      tester,
      const PlaceSearchState(query: '車站', results: [_suggestion]),
    );
    final row = tester.widget<Dismissible>(find.byType(Dismissible));
    expect(row.key, const ValueKey('dismiss-result-id'));
    expect(row.direction, DismissDirection.startToEnd);
    expect(row.secondaryBackground, isNull);
    expect(row.background, isNotNull);
  });

  testWidgets('a search in flight shows five placeholder rows', (tester) async {
    await show(
      tester,
      const PlaceSearchState(query: '車', loading: true),
      animating: true,
    );
    final keys = [
      for (final row in tester.widgetList<Dismissible>(
        find.byType(Dismissible),
      ))
        row.key,
    ];
    expect(keys.take(2), const [
      ValueKey('dismiss-result-skeleton-0'),
      ValueKey('dismiss-result-skeleton-1'),
    ]);
    expect(find.text('囗' * 10), findsWidgets);
  });

  testWidgets('no match states itself with a muted glyph', (tester) async {
    await show(tester, const PlaceSearchState(query: 'zzz'));
    expect(find.byIcon(Icons.search_off_rounded), findsOneWidget);
    expect(find.text(i18n.goNoPlaceMatch), findsOneWidget);
  });

  testWidgets('switching to results slides them up, never down', (
    tester,
  ) async {
    final bloc = await show(tester, const PlaceSearchState());
    bloc.show(const PlaceSearchState(query: '車站', results: [_suggestion]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    final offsets = [
      for (final slide in tester.widgetList<SlideTransition>(
        find.byType(SlideTransition),
      ))
        slide.position.value.dy,
    ];
    expect(offsets.where((dy) => dy < 0), isEmpty);
    await tester.pumpAndSettle();
  });
}

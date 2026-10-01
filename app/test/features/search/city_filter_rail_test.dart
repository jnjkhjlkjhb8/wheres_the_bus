import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/search_recent_repository.dart';
import 'package:wheres_the_bus/data/repositories/search_repository.dart';
import 'package:wheres_the_bus/features/search/bloc/search_bloc.dart';
import 'package:wheres_the_bus/features/search/bloc/search_event.dart';
import 'package:wheres_the_bus/features/search/view/search_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

void main() {
  testWidgets('renders one chip per city, in Chinese, none selected', (
    tester,
  ) async {
    final bloc = _bloc(
      results: [
        _result('a', 'Taipei'),
        _result('b', 'Taipei'),
        _result('c', 'NewTaipei'),
      ],
    );
    addTearDown(bloc.close);

    await _pump(tester, bloc);
    bloc.add(const SearchQueryChanged('中正路'));
    await _settle(tester);

    // The raw TDX codes never reach the screen.
    expect(find.text('台北市'), findsOneWidget);
    expect(find.text('新北市'), findsOneWidget);
    expect(find.text('Taipei'), findsNothing);
    expect(find.text('NewTaipei'), findsNothing);
  });

  testWidgets('stays out of the way when the results are all one city', (
    tester,
  ) async {
    final bloc = _bloc(
      results: [_result('a', 'Taipei'), _result('b', 'Taipei')],
    );
    addTearDown(bloc.close);

    await _pump(tester, bloc);
    bloc.add(const SearchQueryChanged('紅30'));
    await _settle(tester);

    // One city is not a choice: no chip, and no row taking vertical space
    // away from the results.
    expect(find.text('台北市'), findsNothing);
    expect(find.bySemanticsLabel('縣市篩選'), findsNothing);
  });

  testWidgets('tapping a chip filters the list and keeps the way back', (
    tester,
  ) async {
    final bloc = _bloc(
      results: [_result('a', 'Taipei'), _result('b', 'Kaohsiung')],
      byCity: {
        'Kaohsiung': [_result('b', 'Kaohsiung')],
      },
    );
    addTearDown(bloc.close);

    await _pump(tester, bloc);
    bloc.add(const SearchQueryChanged('中正路'));
    await _settle(tester);

    await tester.tap(find.text('高雄市'));
    await _settle(tester);

    expect(bloc.state.city, 'Kaohsiung');
    // Both chips survive the filter — a row that collapsed to the selected
    // city would leave no way back to the others.
    expect(find.text('台北市'), findsOneWidget);
    expect(find.text('高雄市'), findsOneWidget);
  });

  testWidgets('chips keep a 44pt touch target at a large text scale', (
    tester,
  ) async {
    final bloc = _bloc(
      results: [_result('a', 'Taipei'), _result('b', 'Kaohsiung')],
    );
    addTearDown(bloc.close);

    // Settings offers a large-text mode, and a filter row is exactly the kind
    // of small control that quietly falls under the platform minimum there.
    await _pump(tester, bloc, textScale: 1.6);
    bloc.add(const SearchQueryChanged('中正路'));
    await _settle(tester);

    final chip = find.ancestor(
      of: find.text('台北市'),
      matching: find.byType(Pressable),
    );
    expect(tester.getSize(chip.first).height, greaterThanOrEqualTo(44));
  });

  testWidgets('a filter with no matches still shows the chips', (tester) async {
    final bloc = _bloc(
      results: [_result('a', 'Taipei'), _result('b', 'Kaohsiung')],
      byCity: const {'Kaohsiung': []},
    );
    addTearDown(bloc.close);

    await _pump(tester, bloc);
    bloc.add(const SearchQueryChanged('中正路'));
    await _settle(tester);
    await tester.tap(find.text('高雄市'));
    await _settle(tester);

    // The empty state must not be a dead end: the chip that caused it is
    // still on screen to be tapped off.
    expect(find.text('高雄市'), findsOneWidget);
    expect(find.byIcon(Icons.search_off_rounded), findsOneWidget);
  });
}

SearchBloc _bloc({
  required List<SearchResult> results,
  Map<String, List<SearchResult>>? byCity,
}) => SearchBloc(
  searchRepository: _FakeSearchRepository(results: results, byCity: byCity),
  recentRepository: _FakeSearchRecentRepository(),
  // Without this the bloc reaches the real geolocator plugin, which has no
  // implementation under `flutter test` and never answers — these tests are
  // about the chip row, not about where the rider is.
  locationService: _FakeLocationService(),
);

class _FakeLocationService implements LocationService {
  @override
  Future<Position?> lastKnownPosition() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not used by these tests',
  );
}

Future<void> _pump(
  WidgetTester tester,
  SearchBloc bloc, {
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp.router(
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      theme: AppTheme.light,
      routerConfig: GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, state) => MediaQuery(
              data: MediaQueryData(
                textScaler: TextScaler.linear(textScale),
              ),
              child: SearchScreen(bloc: bloc),
            ),
          ),
        ],
      ),
    ),
  );
  await tester.pump();
}

/// Past the query debounce, then through the resulting rebuild.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

class _FakeSearchRepository implements SearchRepository {
  _FakeSearchRepository({required this.results, this.byCity});

  final List<SearchResult> results;
  final Map<String, List<SearchResult>>? byCity;

  @override
  Future<List<SearchResult>> search(
    String query, {
    int limit = 20,
    String? city,
  }) async => city == null ? results : (byCity?[city] ?? results);
}

class _FakeSearchRecentRepository implements SearchRecentRepository {
  @override
  List<SearchResult> all() => const [];

  @override
  Future<void> add(SearchResult result) async {}

  @override
  Future<void> remove(SearchResult result) async {}

  @override
  Future<void> restore(SearchResult result, int index) async {}

  @override
  Future<void> clear() async {}
}

SearchResult _result(String uid, String city) => SearchResult(
  type: SearchResultType.busStation,
  uid: uid,
  name: '中正路',
  subtitle: '往南港',
  city: city,
);

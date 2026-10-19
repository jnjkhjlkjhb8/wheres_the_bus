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
import 'package:wheres_the_bus/features/search/view/search_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

const _item = SearchResult(
  type: SearchResultType.busRoute,
  uid: 'u1',
  name: 'RowName',
  subtitle: 'RowSub',
);

const _other = SearchResult(
  type: SearchResultType.busStation,
  uid: 'u2',
  name: 'OtherName',
  subtitle: 'OtherSub',
);

class _Search implements SearchRepository {
  @override
  Future<List<SearchResult>> search(
    String query, {
    int limit = 20,
    String? city,
  }) async => const [_item, _other];
}

class _History implements SearchRecentRepository {
  @override
  List<SearchResult> all() => const [_item, _other];
  @override
  Future<void> add(SearchResult result) async {}
  @override
  Future<void> remove(SearchResult result) async {}
  @override
  Future<void> restore(SearchResult result, int index) async {}
  @override
  Future<void> clear() async {}
}

class _Location implements LocationService {
  @override
  Future<Position?> lastKnownPosition() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> mount(WidgetTester tester, {String? query}) async {
    final bloc = SearchBloc(
      searchRepository: _Search(),
      recentRepository: _History(),
      locationService: _Location(),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => SearchScreen(bloc: bloc, initialQuery: query),
        ),
      ],
    );
    addTearDown(bloc.close);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  void expectLineHeights(WidgetTester tester) {
    expect(tester.widget<Text>(find.text('RowName')).style!.height, 1.3);
    expect(tester.widget<Text>(find.text('RowSub')).style!.height, 1.3);
  }

  testWidgets('recent rows: key, divider thickness and text line height', (
    tester,
  ) async {
    await mount(tester);
    expect(
      find.byKey(const ValueKey('recent-busRoute-u1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('recent-busStation-u2')),
      findsOneWidget,
    );
    expectLineHeights(tester);
    expect(tester.widget<Divider>(find.byType(Divider)).thickness, 0.5);
  });

  testWidgets('result rows: text line height', (tester) async {
    await mount(tester, query: 'q');
    expectLineHeights(tester);
    expect(tester.widget<Divider>(find.byType(Divider)).thickness, 0.5);
  });
}

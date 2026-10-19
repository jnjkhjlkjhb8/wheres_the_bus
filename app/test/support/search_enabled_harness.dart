import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/search_recent_repository.dart';
import 'package:wheres_the_bus/data/repositories/search_repository.dart';
import 'package:wheres_the_bus/features/search/bloc/search_bloc.dart';
import 'package:wheres_the_bus/features/search/genui/bloc/genui_bloc.dart';
import 'package:wheres_the_bus/features/search/genui/data/genui_service.dart';
import 'package:wheres_the_bus/features/search/genui/model/genui_node.dart';
import 'package:wheres_the_bus/features/search/genui/view/genui_ask_lane.dart';
import 'package:wheres_the_bus/features/search/view/search_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

class _Search implements SearchRepository {
  @override
  Future<List<SearchResult>> search(
    String query, {
    int limit = 20,
    String? city,
  }) async => [];
}

class _History implements SearchRecentRepository {
  @override
  List<SearchResult> all() => [];
  @override
  Future<void> add(SearchResult result) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Location implements LocationService {
  @override
  Future<Position?> lastKnownPosition() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Ai extends GenUiService {
  final prompts = <String>[];
  @override
  Future<GenUiAnswer> ask(
    String prompt, {
    void Function(GenUiPhase phase, String? query)? onPhase,
  }) async {
    prompts.add(prompt);
    return const GenUiAnswer(nodes: [GenUiText('Answer')], refs: {});
  }
}

void main() {
  testWidgets(
    'AI lane synchronizes changed query, ignores empty prompt and reasks',
    (tester) async {
      expect(FirebaseGate.enabled, isTrue);
      final service = _Ai();
      final ai = GenUiBloc(service: service);
      final search = SearchBloc(
        searchRepository: _Search(),
        recentRepository: _History(),
        locationService: _Location(),
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => SearchScreen(
              bloc: search,
              genUiBloc: ai,
              initialQuery: 'Original',
            ),
          ),
          GoRoute(
            path: '/bus/route/:subRouteUid',
            builder: (_, _) => const Scaffold(body: Text('Selected route')),
          ),
        ],
      );
      addTearDown(ai.close);
      addTearDown(search.close);
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppI18n.localizationsDelegates,
          supportedLocales: AppI18n.supportedLocales,
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      final lane = tester.widget<GenUiAskLane>(find.byType(GenUiAskLane));
      lane.onAsk('   ');
      await tester.pump();
      expect(service.prompts, isEmpty);
      lane.onAsk('  New question  ');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(service.prompts, ['New question']);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'New question',
      );
      lane.onAsk('New question');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(service.prompts, ['New question', 'New question']);
      expect(search.state.query, 'New question');
      lane.onOpen(
        const SearchResult(
          type: SearchResultType.busRoute,
          uid: '307',
          name: '307',
          subtitle: 'Destination',
        ),
      );
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/bus/route/307');
      expect(find.text('Selected route'), findsOneWidget);
    },
  );
}

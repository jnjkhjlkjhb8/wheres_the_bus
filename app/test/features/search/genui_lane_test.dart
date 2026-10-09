// The lane is the search screen's own surface, so these render it rather than
// asserting on state: the test flavor has no Maps key and cannot be launched.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/features/search/genui/bloc/genui_bloc.dart';
import 'package:wheres_the_bus/features/search/genui/data/genui_service.dart';
import 'package:wheres_the_bus/features/search/genui/model/genui_node.dart';
import 'package:wheres_the_bus/features/search/genui/view/genui_ask_lane.dart';
import 'package:wheres_the_bus/features/search/genui/view/genui_renderer.dart';

import '../../support/helpers/i18n.dart';

class _FakeService extends GenUiService {
  const _FakeService(this._impl);
  final Future<GenUiAnswer> Function(String prompt) _impl;

  @override
  Future<GenUiAnswer> ask(
    String prompt, {
    void Function(GenUiPhase phase, String? query)? onPhase,
  }) => _impl(prompt);
}

const _route = SearchResult(
  type: SearchResultType.busRoute,
  uid: 'TPE307',
  name: '307',
  subtitle: '板橋 ↔ 撫遠街',
);

const _stop = SearchResult(
  type: SearchResultType.busStation,
  uid: 'STOP1',
  name: '台北車站（忠孝西路）',
  subtitle: '台北市',
  city: 'Taipei',
);

const _answer = GenUiAnswer(
  nodes: [
    GenUiText('搭 307 直達,不用轉乘。'),
    GenUiRoute(title: '模型寫的標題', badges: ['公車'], refUid: 'TPE307'),
    GenUiChip(label: '淡水站', query: '淡水站'),
  ],
  refs: {'TPE307': _route},
);

BusStopArrival _arrival(String name, int seconds) => BusStopArrival(
  stationId: 'STOP1',
  subRouteUid: 'S$name',
  routeName: name,
  destination: '淡水',
  estimateSeconds: seconds,
);

Future<void> _reach(GenUiBloc bloc, GenUiStatus status, GenUiEvent event) {
  final reached = bloc.stream.firstWhere((s) => s.status == status);
  bloc.add(event);
  return reached;
}

/// Long enough for the renderer's 30ms-per-node stagger to finish.
const _staggerDone = Duration(milliseconds: 600);

Future<void> _pumpLane(
  WidgetTester tester, {
  required String query,
  required GenUiBloc bloc,
  ValueChanged<String>? onAsk,
  ValueChanged<SearchResult>? onOpen,
}) => tester.pumpWidget(
  i18nApp(
    BlocProvider.value(
      value: bloc,
      child: Scaffold(
        body: GenUiLane(
          query: query,
          onAsk: onAsk ?? (_) {},
          onOpen: onOpen ?? (_) {},
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('empty query teaches what can be asked', (tester) async {
    final bloc = GenUiBloc(service: _FakeService((_) async => _answer));
    addTearDown(bloc.close);
    final asked = <String>[];
    await _pumpLane(tester, query: '', bloc: bloc, onAsk: asked.add);

    expect(find.text(zhStrings.genuiAskInvite), findsOne);
    expect(find.text(zhStrings.genuiAskExample1), findsOne);
    expect(find.text(zhStrings.genuiAskExample2), findsOne);

    await tester.tap(find.text(zhStrings.genuiAskExample1));
    expect(asked, [zhStrings.genuiAskExample1]);
  });

  testWidgets('a typed query offers to be asked', (tester) async {
    final bloc = GenUiBloc(service: _FakeService((_) async => _answer));
    addTearDown(bloc.close);
    final asked = <String>[];
    await _pumpLane(
      tester,
      query: '從台北車站怎麼去淡水',
      bloc: bloc,
      onAsk: asked.add,
    );

    final label = zhStrings.genuiAskQuery('從台北車站怎麼去淡水');
    expect(find.text(label), findsOne);
    await tester.tap(find.text(label));
    expect(asked, ['從台北車站怎麼去淡水']);
  });

  testWidgets('stopping a request does not wipe the answer', (tester) async {
    final gate = Completer<GenUiAnswer>();
    var call = 0;
    final bloc = GenUiBloc(
      service: _FakeService(
        (_) => call++ == 0 ? Future.value(_answer) : gate.future,
      ),
    );
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(_answer);
      return bloc.close();
    });

    await _reach(bloc, GenUiStatus.content, const GenUiAsked('第一個問題'));
    await _pumpLane(tester, query: '第一個問題', bloc: bloc);
    await tester.pump(_staggerDone);
    expect(find.text('搭 307 直達,不用轉乘。'), findsOne);

    await _reach(bloc, GenUiStatus.loading, const GenUiAsked('第二個問題'));
    await tester.pump();
    expect(find.text(zhStrings.genuiStop), findsOne);

    await tester.tap(find.text(zhStrings.genuiStop));
    await tester.pump();
    await tester.pump(_staggerDone);
    // Back to the first answer, not to an empty lane.
    expect(find.text('搭 307 直達,不用轉乘。'), findsOne);
    expect(find.text(zhStrings.genuiCollapse), findsOne);

    // Release the cancelled request so its timeout timer is disposed with the
    // test rather than outliving the widget tree.
    gate.complete(_answer);
    await tester.pump();
    expect(find.text(zhStrings.genuiCollapse), findsOne);
  });

  testWidgets('a card opens its result, a chip re-asks in place', (
    tester,
  ) async {
    final bloc = GenUiBloc(service: _FakeService((_) async => _answer));
    addTearDown(bloc.close);
    final opened = <SearchResult>[];
    final asked = <String>[];

    await _reach(bloc, GenUiStatus.content, const GenUiAsked('307 怎麼搭'));
    await _pumpLane(
      tester,
      query: '307 怎麼搭',
      bloc: bloc,
      onAsk: asked.add,
      onOpen: opened.add,
    );
    await tester.pump(_staggerDone);

    // The resolved result's own name wins over whatever the model titled it.
    expect(find.text('307'), findsOne);
    expect(find.text('模型寫的標題'), findsNothing);

    await tester.tap(find.text('307'));
    expect(opened.single.uid, 'TPE307');

    await tester.tap(find.text('淡水站'));
    expect(asked, ['淡水站']);
  });

  testWidgets('offline names the cause and retries the same prompt', (
    tester,
  ) async {
    final bloc = GenUiBloc(
      service: _FakeService((_) => throw const SocketException('down')),
    );
    addTearDown(bloc.close);
    final asked = <String>[];

    await _reach(
      bloc,
      GenUiStatus.error,
      const GenUiAsked('從台北車站怎麼去淡水'),
    );
    await _pumpLane(
      tester,
      query: '從台北車站怎麼去淡水',
      bloc: bloc,
      onAsk: asked.add,
    );
    await tester.pump();

    expect(find.text(zhStrings.genuiOffline), findsOne);
    await tester.tap(find.text(zhStrings.commonRetryShort));
    expect(asked, ['從台北車站怎麼去淡水']);
  });

  testWidgets('the loading skeleton is as wide as the answered card', (
    tester,
  ) async {
    // Both the skeleton card and _RouteCard pad with EdgeInsets.all(14); no
    // other container in this tree shares that padding, so it disambiguates.
    Finder cardFinder() => find.byWidgetPredicate(
      (w) => w is Container && w.padding == const EdgeInsets.all(14),
    );

    final gate = Completer<GenUiAnswer>();
    final bloc = GenUiBloc(service: _FakeService((_) => gate.future));
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(_answer);
      return bloc.close();
    });

    await _reach(bloc, GenUiStatus.loading, const GenUiAsked('307 怎麼搭'));
    await _pumpLane(tester, query: '307 怎麼搭', bloc: bloc);
    await tester.pump();
    final loadingWidth = tester.getSize(cardFinder().first).width;

    gate.complete(_answer);
    await tester.pump();
    await tester.pump(_staggerDone);
    final contentWidth = tester.getSize(cardFinder().first).width;

    expect(loadingWidth, contentWidth);
  });

  testWidgets('a stop card shows live arrivals, soonest first', (tester) async {
    await tester.pumpWidget(
      i18nApp(
        Scaffold(
          body: SingleChildScrollView(
            child: GenUiRenderer(
              nodes: const [
                GenUiRoute(title: '台北車站', badges: [], refUid: 'STOP1'),
              ],
              refs: const {'STOP1': _stop},
              onAsk: (_) {},
              onOpen: (_) {},
              etaSource: (stop) => Stream.value([
                _arrival('862', 840),
                _arrival('紅33', 0),
                _arrival('指南1', 120),
              ]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(zhStrings.etaArriving), findsOne);
    // Sorted by rank, not by the order the feed sent them.
    final routes = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .where((t) => t == '862' || t == '紅33' || t == '指南1')
        .toList();
    expect(routes, ['紅33', '指南1', '862']);
  });
}

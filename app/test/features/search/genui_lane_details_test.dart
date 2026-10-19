import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/search/genui/bloc/genui_bloc.dart';
import 'package:wheres_the_bus/features/search/genui/data/genui_service.dart';
import 'package:wheres_the_bus/features/search/genui/model/genui_node.dart';
import 'package:wheres_the_bus/features/search/genui/view/genui_ask_lane.dart';
import 'package:wheres_the_bus/shared/widgets/app_spinner.dart';

import '../../support/helpers/i18n.dart';

class _Service extends GenUiService {
  const _Service(this._impl);
  final Future<GenUiAnswer> Function(String prompt) _impl;

  @override
  Future<GenUiAnswer> ask(
    String prompt, {
    void Function(GenUiPhase phase, String? query)? onPhase,
  }) => _impl(prompt);
}

const _answer = GenUiAnswer(nodes: [GenUiText('answer')], refs: {});

Future<void> _pumpLane(WidgetTester tester, GenUiBloc bloc, String query) =>
    tester.pumpWidget(
      i18nApp(
        BlocProvider.value(
          value: bloc,
          child: Scaffold(
            body: GenUiLane(query: query, onAsk: (_) {}, onOpen: (_) {}),
          ),
        ),
      ),
    );

Future<void> _reach(GenUiBloc bloc, GenUiStatus status, String prompt) {
  final reached = bloc.stream.firstWhere((s) => s.status == status);
  bloc.add(GenUiAsked(prompt));
  return reached;
}

void main() {
  testWidgets('the lane never grows past 55% of the screen', (tester) async {
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bloc = GenUiBloc(service: _Service((_) async => _answer));
    addTearDown(bloc.close);
    await _pumpLane(tester, bloc, '');
    final box = tester.widget<ConstrainedBox>(
      find
          .ancestor(
            of: find.byType(SingleChildScrollView),
            matching: find.byType(ConstrainedBox),
          )
          .first,
    );
    expect(box.constraints.maxHeight, 550);
  });

  testWidgets('an answered query is not offered again, a new one is', (
    tester,
  ) async {
    final bloc = GenUiBloc(service: _Service((_) async => _answer));
    addTearDown(bloc.close);
    await _reach(bloc, GenUiStatus.content, 'first');

    await _pumpLane(tester, bloc, 'first');
    expect(find.text(zhStrings.genuiAskQuery('first')), findsNothing);
    expect(find.text(zhStrings.genuiCollapse), findsOneWidget);

    await _pumpLane(tester, bloc, 'second');
    expect(find.text(zhStrings.genuiAskQuery('second')), findsOneWidget);
  });

  testWidgets('while a request runs nothing new can be asked', (tester) async {
    final gate = Completer<GenUiAnswer>();
    final bloc = GenUiBloc(service: _Service((_) => gate.future));
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(_answer);
      return bloc.close();
    });
    await _reach(bloc, GenUiStatus.loading, 'first');

    await _pumpLane(tester, bloc, 'another');
    expect(find.text(zhStrings.genuiAskQuery('another')), findsNothing);
    expect(find.byType(AppSpinner), findsOneWidget);
    expect(find.text(zhStrings.genuiThinking), findsOneWidget);

    gate.complete(_answer);
    await tester.pump();
  });
}

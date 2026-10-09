import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_bloc.dart';
import 'package:wheres_the_bus/shared/widgets/main_scaffold.dart';
import 'package:wheres_the_bus/shared/widgets/nav_mini_bar.dart';

import '../../support/helpers/i18n.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget shell) async {
    final alertBloc = AlertBloc();
    final planBloc = PlanBloc();
    addTearDown(alertBloc.close);
    addTearDown(planBloc.close);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AlertBloc>.value(value: alertBloc),
          BlocProvider<PlanBloc>.value(value: planBloc),
        ],
        child: i18nApp(MainScaffold(shell: shell)),
      ),
    );
  }

  testWidgets('renders the mini bar over the branch content', (tester) async {
    await pump(tester, const Text('branch content'));
    expect(find.byType(NavMiniBar), findsOneWidget);
    expect(find.text('branch content'), findsOneWidget);
  });

  testWidgets('passes the real safe area through to the branch untouched', (
    tester,
  ) async {
    late EdgeInsets padding;
    late EdgeInsets viewPadding;
    await pump(
      tester,
      Builder(
        builder: (context) {
          padding = MediaQuery.paddingOf(context);
          viewPadding = MediaQuery.viewPaddingOf(context);
          return const Text('branch content');
        },
      ),
    );
    await tester.pumpAndSettle();

    final media = MediaQueryData.fromView(tester.view);
    expect(padding.top, media.padding.top);
    expect(viewPadding.top, media.viewPadding.top);
  });
}

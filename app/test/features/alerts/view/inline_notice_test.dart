import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/notice_tone.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/data/repositories/alert_repository.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_event.dart';
import 'package:wheres_the_bus/features/alerts/view/inline_notice.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import '../../../support/helpers/i18n.dart';
import '../../../support/helpers/in_memory_settings_store.dart';

const _source = AlertSourceId(AlertSourceKind.busAlert, 'Taipei');

AlertViewModel _busAlert(
  String message,
  List<String> routeKeys, {
  AlertSeverity level = AlertSeverity.red,
}) => AlertViewModel(
  message: message,
  level: level,
  routeType: 'bus',
  routeKeys: routeKeys,
  source: _source,
);

void main() {
  Future<AlertBloc> pump(
    WidgetTester tester, {
    required List<AlertViewModel> notices,
    required Set<String> routeKeys,
    String routeType = 'bus',
  }) async {
    final bloc = AlertBloc(
      repository: AlertRepository(
        settings: SettingsRepository(store: InMemorySettingsStore(const {})),
      ),
    );
    addTearDown(bloc.close);
    bloc.add(AlertReceived(_source, notices));
    await tester.pumpWidget(
      i18nApp(
        BlocProvider<AlertBloc>.value(
          value: bloc,
          child: Scaffold(
            body: InlineNotice(routeType: routeType, routeKeys: routeKeys),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return bloc;
  }

  testWidgets("shows a notice that names one of this page's routes", (
    tester,
  ) async {
    await pump(
      tester,
      notices: [
        _busAlert('307 停駛', ['TPE10133']),
      ],
      routeKeys: {'TPE10133', 'TPE10134'},
    );
    expect(find.text('307 停駛'), findsOneWidget);
  });

  testWidgets('stays empty for a notice about a route this page does not '
      'serve — the predecessor rendered the first global alert here', (
    tester,
  ) async {
    await pump(
      tester,
      notices: [
        _busAlert('672 停駛', ['TPE99999']),
      ],
      routeKeys: {'TPE10133'},
    );
    expect(find.text('672 停駛'), findsNothing);
  });

  testWidgets('a notice naming no route is system-wide and still shows', (
    tester,
  ) async {
    await pump(
      tester,
      notices: [_busAlert('北市公車今日全面停駛', const [])],
      routeKeys: {'TPE10133'},
    );
    expect(find.text('北市公車今日全面停駛'), findsOneWidget);
  });

  testWidgets('ignores a notice from another transit domain', (tester) async {
    await pump(
      tester,
      notices: [_busAlert('板南線停駛', const [])],
      routeKeys: {'BL'},
      routeType: 'mrt',
    );
    expect(find.text('板南線停駛'), findsNothing);
  });

  testWidgets('shows a route notice the rider never favorited', (tester) async {
    // 訂閱範圍 stays empty: the inline layer must not inherit the inbox
    // filter, or a stop screen would go silent about the route on screen.
    final bloc = await pump(
      tester,
      notices: [
        _busAlert('307 停駛', ['TPE10133']),
      ],
      routeKeys: {'TPE10133'},
    );
    expect(bloc.state.scope, isEmpty);
    expect(find.text('307 停駛'), findsOneWidget);
  });

  group('which notice wins', () {
    testWidgets('a critical notice outranks a newer caution', (tester) async {
      await pump(
        tester,
        notices: [
          _busAlert('停駛', const []),
          _busAlert('延誤', const [], level: AlertSeverity.yellow),
        ],
        routeKeys: {'TPE10133'},
      );
      expect(find.text('停駛'), findsOneWidget);
      expect(find.text('延誤'), findsNothing);
    });

    testWidgets('within a tone the newest notice wins', (tester) async {
      await pump(
        tester,
        notices: [
          _busAlert('舊停駛', const []),
          _busAlert('新停駛', const []),
        ],
        routeKeys: {'TPE10133'},
      );
      expect(find.text('新停駛'), findsOneWidget);
      expect(find.text('舊停駛'), findsNothing);

      await pump(
        tester,
        notices: [
          _busAlert('舊延誤', const [], level: AlertSeverity.yellow),
          _busAlert('新延誤', const [], level: AlertSeverity.yellow),
        ],
        routeKeys: {'TPE10133'},
      );
      expect(find.text('新延誤'), findsOneWidget);
      expect(find.text('舊延誤'), findsNothing);
    });
  });

  group('the card', () {
    testWidgets('a critical notice carries the warning icon', (tester) async {
      await pump(
        tester,
        notices: [_busAlert('停駛', const [])],
        routeKeys: {'TPE10133'},
      );
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
    });

    testWidgets('a caution notice carries the info icon', (tester) async {
      await pump(
        tester,
        notices: [_busAlert('延誤', const [], level: AlertSeverity.yellow)],
        routeKeys: {'TPE10133'},
      );
      expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    });

    testWidgets('sets the title and the footer at their own type sizes', (
      tester,
    ) async {
      await pump(
        tester,
        notices: [_busAlert('停駛', const [])],
        routeKeys: {'TPE10133'},
      );
      final context = tester.element(find.byType(InlineNotice));
      final ink = noticeColors(
        NoticeTone.critical,
        Theme.of(context).colorScheme,
      ).ink;

      final title = tester.widget<Text>(find.text('停駛')).style!;
      expect(title.fontSize, 13.5);
      expect(title.height, 1.3);
      expect(title.fontWeight, FontWeight.w600);
      expect(title.color, ink);

      final footer = tester
          .widget<Text>(find.text(AppI18n.of(context).commonTapForDetails))
          .style!;
      expect(footer.fontSize, 11);
      expect(footer.height, 1.2);
      expect(footer.color, ink.withValues(alpha: 0.8));
    });
  });
}

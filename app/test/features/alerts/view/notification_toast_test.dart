import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/router/app_router.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/data/repositories/alert_repository.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_event.dart';
import 'package:wheres_the_bus/features/alerts/view/notification_toast.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import '../../../support/helpers/in_memory_settings_store.dart';

const _source = AlertSource(AlertSourceKind.metro, 'TRTC');

Future<void> _location(String path) =>
    AppRouter.router.routerDelegate.setNewRoutePath(
      AppRouter.router.configuration.findMatch(Uri.parse(path)),
    );

Future<AlertBloc> _mount(WidgetTester tester, {bool reduced = false}) async {
  final bloc = AlertBloc(
    repository: AlertRepository(
      settings: SettingsRepository(store: InMemorySettingsStore(const {})),
    ),
  );
  addTearDown(bloc.close);
  await _location('/settings');
  await tester.pumpWidget(
    BlocProvider.value(
      value: bloc,
      child: MaterialApp(
        navigatorKey: AppRouter.rootNavigatorKey,
        theme: reduced ? ThemeData.dark() : ThemeData.light(),
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: const NotificationToastHost(
            child: Scaffold(body: Text('screen')),
          ),
        ),
      ),
    ),
  );
  return bloc;
}

Future<void> _receive(
  WidgetTester tester,
  AlertBloc bloc,
  String message, {
  String? title,
}) async {
  bloc.add(
    AlertReceived(_source, [
      AlertViewModel(
        message: message,
        title: title,
        level: AlertSeverity.red,
        source: _source,
      ),
    ]),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('home owns interruptions and navigation never replays them', (
    tester,
  ) async {
    final bloc = await _mount(tester);
    await _location('/');
    await _receive(tester, bloc, 'home notice');
    expect(find.text('home notice'), findsNothing);
    await _location('/settings');
    bloc.add(const AlertScopeChanged({'bus:other'}));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('home notice'), findsNothing);
    await _receive(tester, bloc, 'new disruption', title: 'new title');
    expect(find.text('new title'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('new title'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('new arrivals replace content and tapping opens inbox', (
    tester,
  ) async {
    final bloc = await _mount(tester);
    await _receive(tester, bloc, 'first');
    await tester.pump(const Duration(seconds: 3));
    await _receive(tester, bloc, 'second');
    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('second'), findsOneWidget);
    await tester.tap(find.text('second'));
    await tester.pumpAndSettle();
    expect(find.text('通知'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    expect(bloc.state.unreadCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  for (final reduced in [false, true]) {
    testWidgets(
      'drag holds timer, cancellation restores, release dismisses '
      '(reduced=$reduced)',
      (tester) async {
        final bloc = await _mount(tester, reduced: reduced);
        await _receive(tester, bloc, 'gesture notice');
        var gesture = await tester.startGesture(
          tester.getCenter(find.text('gesture notice')),
        );
        await gesture.moveBy(const Offset(0, 25));
        await tester.pump();
        await gesture.moveBy(const Offset(0, 20));
        await tester.pump(const Duration(seconds: 6));
        expect(find.text('gesture notice'), findsOneWidget);
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(find.text('gesture notice'), findsOneWidget);
        gesture = await tester.startGesture(
          tester.getCenter(find.text('gesture notice')),
        );
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump(const Duration(milliseconds: 300));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.text('gesture notice'), findsOneWidget);
        gesture = await tester.startGesture(
          tester.getCenter(find.text('gesture notice')),
        );
        await gesture.moveBy(const Offset(0, -20));
        await tester.pump();
        await gesture.moveBy(const Offset(0, -110));
        await tester.pump(const Duration(milliseconds: 300));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.text('gesture notice'), findsNothing);
        await _receive(tester, bloc, 'flick notice');
        await tester.fling(
          find.text('flick notice'),
          const Offset(0, -80),
          600,
        );
        await tester.pumpAndSettle();
        expect(find.text('flick notice'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

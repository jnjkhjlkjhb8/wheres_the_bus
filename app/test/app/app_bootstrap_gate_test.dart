import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/app/app.dart';
import 'package:wheres_the_bus/core/bootstrap/app_bootstrap.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/features/alerts/view/notification_toast.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_bloc.dart';

void main() {
  setUpAll(() async {
    Hive.init('./.dart_tool/hive_test_app_gate');
    Future<void> noopBinding() async {}
    await HiveStore.init(initBinding: noopBinding);
  });

  GoRouter testRouter() => GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) =>
            const Scaffold(body: Text('home-placeholder')),
      ),
    ],
  );

  AppBootstrapController pendingController() => AppBootstrapController(
    initHive: () => Completer<void>().future,
    initGrpc: () => Completer<void>().future,
    initFirebase: () async {},
    initPowerSync: () async {},
  );

  testWidgets('initializing shows a splash and no main UI or retry', (
    tester,
  ) async {
    final controller = pendingController();
    addTearDown(controller.dispose);
    unawaited(controller.start());

    await tester.pumpWidget(
      App(bootstrap: controller, debugRouter: testRouter()),
    );
    await tester.pump();

    expect(controller.state, AppBootstrapState.initializing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const Key('bootstrapRetryButton')), findsNothing);
    expect(find.byType(NotificationToastHost), findsNothing);
  });

  testWidgets('essential failure shows retry and no main UI', (tester) async {
    final controller = AppBootstrapController(
      initHive: () async => throw StateError('disk full'),
      initGrpc: () async {},
      initFirebase: () async {},
      initPowerSync: () async {},
    );
    addTearDown(controller.dispose);
    await controller.start();

    await tester.pumpWidget(
      App(bootstrap: controller, debugRouter: testRouter()),
    );
    await tester.pump();

    expect(controller.state, AppBootstrapState.failed);
    expect(find.byKey(const Key('bootstrapRetryButton')), findsOneWidget);
    expect(find.byType(NotificationToastHost), findsNothing);
    expect(find.textContaining('儲存空間'), findsOneWidget);
  });

  testWidgets('retry after essential failure recovers and shows main UI', (
    tester,
  ) async {
    var hiveAttempts = 0;
    final controller = AppBootstrapController(
      initHive: () async {
        hiveAttempts++;
        if (hiveAttempts == 1) throw StateError('transient');
      },
      initGrpc: () async {},
      initFirebase: () async {},
      initPowerSync: () async {},
    );
    addTearDown(controller.dispose);
    await controller.start();
    expect(controller.state, AppBootstrapState.failed);

    await tester.pumpWidget(
      App(bootstrap: controller, debugRouter: testRouter()),
    );
    await tester.pump();
    expect(find.byKey(const Key('bootstrapRetryButton')), findsOneWidget);

    await tester.tap(find.byKey(const Key('bootstrapRetryButton')));
    await tester.pumpAndSettle();

    expect(controller.state, AppBootstrapState.ready);
    expect(find.byKey(const Key('bootstrapRetryButton')), findsNothing);
    expect(find.byType(NotificationToastHost), findsOneWidget);
    expect(find.text('home-placeholder'), findsOneWidget);
  });

  testWidgets('MrtTrackBloc can be created from above the MaterialApp', (
    tester,
  ) async {
    final controller = AppBootstrapController(
      initHive: () async {},
      initGrpc: () async {},
      initFirebase: () async {},
      initPowerSync: () async {},
    );
    addTearDown(controller.dispose);
    await controller.start();

    await tester.pumpWidget(
      App(bootstrap: controller, debugRouter: testRouter()),
    );
    await tester.pumpAndSettle();

    // `_AppShell` provides it above the MaterialApp, so its lazy `create` runs
    // without Localizations in scope — reading it must not throw.
    final context = tester.element(find.text('home-placeholder'));
    expect(BlocProvider.of<MrtTrackBloc>(context), isNotNull);
  });

  testWidgets('ready renders the main UI directly', (tester) async {
    final controller = AppBootstrapController(
      initHive: () async {},
      initGrpc: () async {},
      initFirebase: () async {},
      initPowerSync: () async {},
    );
    addTearDown(controller.dispose);
    await controller.start();
    expect(controller.state, AppBootstrapState.ready);

    await tester.pumpWidget(
      App(bootstrap: controller, debugRouter: testRouter()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NotificationToastHost), findsOneWidget);
    expect(find.byKey(const Key('bootstrapRetryButton')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/router/app_router.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/data/repositories/alert_repository.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_event.dart';
import 'package:wheres_the_bus/features/alerts/view/notification_toast.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

import '../../../support/helpers/in_memory_settings_store.dart';

const _source = AlertSource(AlertSourceKind.metro, 'TRTC');

Future<void> _location(String path) =>
    AppRouter.router.routerDelegate.setNewRoutePath(
      AppRouter.router.configuration.findMatch(Uri.parse(path)),
    );

Future<AlertBloc> _mount(
  WidgetTester tester, {
  bool reduced = false,
  ThemeData? theme,
}) async {
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
        theme: theme ?? AppTheme.light,
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

void _announce(AlertBloc bloc, String message) => bloc.add(
  AlertReceived(_source, [
    AlertViewModel(message: message, level: AlertSeverity.red, source: _source),
  ]),
);

/// Announces [message] and lets the entrance run to the end.
Future<void> _showFully(
  WidgetTester tester,
  AlertBloc bloc,
  String message,
) async {
  _announce(bloc, message);
  await tester.pump();
  await tester.pump(AppMotion.sheet);
}

/// Announces [message] and stops [fraction] of the way through the entrance.
Future<void> _showPartly(
  WidgetTester tester,
  AlertBloc bloc,
  String message,
  double fraction,
) async {
  _announce(bloc, message);
  await tester.pump();
  await tester.pump(AppMotion.sheet * fraction);
}

AnimationController _entrance(WidgetTester tester) {
  final builder = find
      .byWidgetPredicate(
        (w) =>
            w is AnimatedBuilder &&
            w.listenable is AnimationController &&
            (w.listenable as AnimationController).duration == AppMotion.sheet,
      )
      .evaluate()
      .first
      .widget;
  return (builder as AnimatedBuilder).listenable as AnimationController;
}

void main() {
  group('drag', () {
    testWidgets('upward travel adds up and tracks the finger 1:1', (
      tester,
    ) async {
      final bloc = await _mount(tester);
      await _showFully(tester, bloc, 'notice');

      // The move that crosses touch slop starts the drag but is not counted.
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('notice')),
      );
      await gesture.moveBy(const Offset(0, -20));
      await gesture.moveBy(const Offset(0, -30));
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();

      expect(_entrance(tester).value, closeTo(1 - 60 / 120, 1e-9));
      await gesture.cancel();
      await tester.pumpAndSettle();
    });

    testWidgets('downward travel past fully shown meets rising resistance', (
      tester,
    ) async {
      final bloc = await _mount(tester);
      await _showPartly(tester, bloc, 'notice', 0.5);
      final grabbedAt = _entrance(tester).value;
      expect(grabbedAt, closeTo(0.5, 0.01));

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('notice')),
      );
      await gesture.moveBy(const Offset(0, 20));
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump();

      // 60px of 120 is an excess of 0.5, which resistance squeezes to 1/3;
      // the tolerance absorbs the sub-pixel drift in the gesture's start.
      expect(_entrance(tester).value, closeTo(grabbedAt + 1 / 3, 0.01));
      await gesture.cancel();
      await tester.pumpAndSettle();
    });

    testWidgets('letting go resumes the auto-hide countdown', (tester) async {
      final bloc = await _mount(tester);
      await _showFully(tester, bloc, 'notice');

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('notice')),
      );
      await gesture.moveBy(const Offset(0, 20));
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('notice'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(find.text('notice'), findsNothing);
    });

    testWidgets(
      'a slow release below halfway springs from where it was let go',
      (
        tester,
      ) async {
        final bloc = await _mount(tester);
        await _showFully(tester, bloc, 'notice');

        final gesture = await tester.startGesture(
          tester.getCenter(find.text('notice')),
        );
        await gesture.moveBy(const Offset(0, -20));
        await gesture.moveBy(const Offset(0, -90));
        await tester.pump(const Duration(milliseconds: 300));
        await gesture.up();
        await tester.pump();

        expect(_entrance(tester).value, closeTo(0.25, 1e-9));
        expect(find.text('notice'), findsOneWidget);
        await tester.pumpAndSettle();
        expect(find.text('notice'), findsNothing);
      },
    );

    testWidgets('with reduce motion a release dismisses at once', (
      tester,
    ) async {
      final bloc = await _mount(tester, reduced: true);
      await _showFully(tester, bloc, 'notice');

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('notice')),
      );
      await gesture.moveBy(const Offset(0, -20));
      await gesture.moveBy(const Offset(0, -90));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pump();

      expect(find.text('notice'), findsNothing);
    });
  });

  group('entrance', () {
    testWidgets('sits 16 in from both edges and 8 below the top', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final bloc = await _mount(tester);
      await _showFully(tester, bloc, 'notice');

      final rect = tester.getRect(find.byType(Pressable));
      expect(rect.left, 16);
      expect(rect.right, 344);
      expect(rect.top, 8);
    });

    testWidgets('slides down and grows from 94% as it arrives', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final bloc = await _mount(tester);
      await _showPartly(tester, bloc, 'notice', 0.5);

      final t = AppMotion.easeOut.transform(0.5);
      final rect = tester.getRect(find.byType(Pressable));
      expect(rect.top, closeTo(8 + (1 - t) * -16, 1e-6));
      expect(rect.width, closeTo(328 * (0.94 + 0.06 * t), 1e-6));
    });
  });

  group('surface', () {
    BoxDecoration cardDecoration(WidgetTester tester) => tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(Pressable),
            matching: find.byType(Container),
          ),
        )
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .firstWhere((d) => d.boxShadow != null && d.boxShadow!.isNotEmpty);

    testWidgets('light is plain white', (tester) async {
      final bloc = await _mount(tester);
      await _showFully(tester, bloc, 'notice');

      expect(cardDecoration(tester).color, Colors.white);
    });

    testWidgets('dark uses the raised surface', (tester) async {
      final bloc = await _mount(tester, theme: AppTheme.dark);
      await _showFully(tester, bloc, 'notice');

      final scheme = Theme.of(tester.element(find.text('notice'))).colorScheme;
      expect(cardDecoration(tester).color, scheme.surfaceContainerHigh);
    });

    testWidgets('the caption under the title is set at 1.2 line height', (
      tester,
    ) async {
      final bloc = await _mount(tester);
      await _showFully(tester, bloc, 'notice');

      final caption = tester.widget<Text>(
        find.text(
          AppI18n.of(
            tester.element(find.text('notice')),
          ).alertJustNowDisruption,
        ),
      );
      expect(caption.style?.height, 1.2);
    });
  });
}

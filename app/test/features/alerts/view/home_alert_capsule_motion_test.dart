import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/data/repositories/alert_repository.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_event.dart';
import 'package:wheres_the_bus/features/alerts/view/home_alert_capsule.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';

import '../../../support/helpers/in_memory_settings_store.dart';

const _source = AlertSource(AlertSourceKind.metro, 'TRTC');

AlertViewModel _notice(String message, {String? title}) => AlertViewModel(
  message: message,
  title: title,
  level: AlertSeverity.red,
  source: _source,
);

void main() {
  late AlertBloc bloc;

  Future<void> pumpCapsule(
    WidgetTester tester,
    List<AlertViewModel> notices, {
    bool reduced = false,
    ThemeData? theme,
  }) async {
    bloc = AlertBloc(
      repository: AlertRepository(
        settings: SettingsRepository(store: InMemorySettingsStore(const {})),
      ),
    );
    addTearDown(bloc.close);
    bloc.add(AlertReceived(_source, notices));
    await bloc.stream.first;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: BlocProvider.value(
            value: bloc,
            child: const Scaffold(body: Center(child: HomeAlertCapsule())),
          ),
        ),
      ),
    );
  }

  Future<void> receive(
    WidgetTester tester,
    List<AlertViewModel> notices,
  ) async {
    bloc.add(AlertReceived(_source, notices));
    await tester.pump();
    await tester.pump();
  }

  double surfaceOpacity(WidgetTester tester) => tester
      .widget<FadeTransition>(
        find.byWidgetPredicate(
          (w) => w is FadeTransition && w.child is ClipRRect,
        ),
      )
      .opacity
      .value;

  Container capsuleBox(WidgetTester tester) => tester.widget<Container>(
    find.descendant(
      of: find.byType(HomeAlertCapsule),
      matching: find.byWidgetPredicate(
        (w) => w is Container && w.decoration is BoxDecoration,
      ),
    ),
  );

  group('reveal', () {
    testWidgets('the surface fades in, from nothing, when it first appears', (
      tester,
    ) async {
      await pumpCapsule(tester, [_notice('停駛')]);
      expect(surfaceOpacity(tester), 0);

      await tester.pumpAndSettle();
      expect(surfaceOpacity(tester), 1);
    });

    testWidgets('with reduce motion it is fully there at once', (tester) async {
      await pumpCapsule(tester, [_notice('停駛')], reduced: true);
      expect(surfaceOpacity(tester), 1);
    });
  });

  group('a replacement alert', () {
    testWidgets('replays the reveal and expands again', (tester) async {
      await pumpCapsule(tester, [
        _notice('完整訊息一', title: '標題一'),
      ]);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('標題一'), findsOneWidget);

      await receive(tester, [_notice('完整訊息二', title: '標題二')]);

      expect(surfaceOpacity(tester), 0);
      await tester.pumpAndSettle();
      expect(find.text('完整訊息二'), findsOneWidget);
      expect(find.text('標題二'), findsNothing);
    });

    testWidgets('with reduce motion shows at once without a replay', (
      tester,
    ) async {
      await pumpCapsule(tester, [_notice('訊息一')], reduced: true);
      await receive(tester, [_notice('訊息二')]);

      expect(surfaceOpacity(tester), 1);
      expect(find.text('訊息二'), findsOneWidget);
    });

    testWidgets('an update that keeps the message does not replay', (
      tester,
    ) async {
      await pumpCapsule(tester, [_notice('停駛', title: '標題')]);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      await receive(tester, [_notice('停駛', title: '標題'), _notice('另一則')]);

      expect(surfaceOpacity(tester), 1);
      expect(find.text('標題'), findsOneWidget);
    });
  });

  group('what rebuilds the capsule', () {
    testWidgets('a change in how many alerts are red updates the count', (
      tester,
    ) async {
      await pumpCapsule(tester, [_notice('甲'), _notice('乙')]);
      await tester.pumpAndSettle();
      expect(find.text('+1'), findsOneWidget);

      await receive(tester, [_notice('甲')]);
      await tester.pumpAndSettle();

      expect(find.text('+1'), findsNothing);
    });

    testWidgets('a new top alert replaces the shown one', (tester) async {
      await pumpCapsule(tester, [_notice('甲')]);
      await tester.pumpAndSettle();

      await receive(tester, [_notice('丙')]);
      await tester.pumpAndSettle();

      expect(find.text('丙'), findsOneWidget);
      expect(find.text('甲'), findsNothing);
    });
  });

  group('surface', () {
    testWidgets('light: a floating shadow, no outline', (tester) async {
      await pumpCapsule(tester, [_notice('停駛')]);
      await tester.pumpAndSettle();

      final decoration = capsuleBox(tester).decoration! as BoxDecoration;
      expect(decoration.border, isNull);
      expect(decoration.boxShadow, AppShadows.floating);
      expect(decoration.borderRadius, BorderRadius.circular(22));
    });

    testWidgets('dark: a hairline outline instead of a shadow', (
      tester,
    ) async {
      await pumpCapsule(tester, [_notice('停駛')], theme: AppTheme.dark);
      await tester.pumpAndSettle();

      final decoration = capsuleBox(tester).decoration! as BoxDecoration;
      final scheme = Theme.of(
        tester.element(find.byType(Scaffold)),
      ).colorScheme;
      expect(decoration.border, Border.all(color: scheme.outlineVariant));
      expect(decoration.boxShadow, isEmpty);
    });

    testWidgets('the capsule is clipped to a full pill', (tester) async {
      await pumpCapsule(tester, [_notice('停駛')]);
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<ClipRRect>(
              find.descendant(
                of: find.byType(HomeAlertCapsule),
                matching: find.byType(ClipRRect),
              ),
            )
            .borderRadius,
        BorderRadius.circular(22),
      );
    });
  });

  group('collapse blur', () {
    testWidgets('the incoming row sharpens from a blur as it settles', (
      tester,
    ) async {
      await pumpCapsule(tester, [_notice('完整訊息', title: '標題')]);
      await tester.pumpAndSettle();
      expect(find.byType(ImageFiltered), findsNothing);

      // The hold expires: the row swaps to its collapsed form.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(AppMotion.short ~/ 2);

      final progress = AppMotion.easeOut.transform(0.5);
      final sigma = (1 - progress) * 2;
      final filters = tester
          .widgetList<ImageFiltered>(find.byType(ImageFiltered))
          .map((f) => f.imageFilter);
      expect(
        filters,
        contains(ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma)),
      );

      await tester.pumpAndSettle();
      expect(find.byType(ImageFiltered), findsNothing);
    });
  });
}

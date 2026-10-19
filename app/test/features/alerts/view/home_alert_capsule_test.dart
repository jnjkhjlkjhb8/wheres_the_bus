import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/data/repositories/alert_repository.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_event.dart';
import 'package:wheres_the_bus/features/alerts/view/home_alert_capsule.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

import '../../../support/helpers/in_memory_settings_store.dart';

const source = AlertSource(AlertSourceKind.metro, 'TRTC');
AlertViewModel notice(String message, {String? title}) => AlertViewModel(
  message: message,
  title: title,
  level: AlertSeverity.red,
  source: source,
);

void main() {
  for (final reduced in [false, true]) {
    testWidgets(
      'capsule collapses and replacement expands with reduce motion $reduced',
      (tester) async {
        final bloc = AlertBloc(
          repository: AlertRepository(
            settings: SettingsRepository(
              store: InMemorySettingsStore(const {}),
            ),
          ),
        );
        addTearDown(bloc.close);
        bloc.add(
          AlertReceived(source, [
            notice('各站班距拉長，請預留轉乘時間', title: '列車延誤'),
            notice('其他路線停駛'),
          ]),
        );
        await bloc.stream.first;
        await tester.pumpWidget(
          MaterialApp(
            theme: reduced ? AppTheme.dark : AppTheme.light,
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
        await tester.pumpAndSettle();
        expect(find.text('各站班距拉長，請預留轉乘時間'), findsOneWidget);
        expect(find.text('+1'), findsOneWidget);
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(find.text('列車延誤'), findsOneWidget);
        expect(find.text('各站班距拉長，請預留轉乘時間'), findsNothing);
        expect(tester.takeException(), isNull);

        bloc.add(AlertReceived(source, [notice('已改為全線停駛')]));
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.text('已改為全線停駛'), findsOneWidget);
        expect(find.text('+1'), findsNothing);
        await tester.drag(find.byType(Dismissible), const Offset(0, -200));
        await tester.pumpAndSettle();
        expect(find.byType(HomeAlertCapsule), findsOneWidget);
        expect(find.text('已改為全線停駛'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/data/repositories/alert_repository.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_event.dart';
import 'package:wheres_the_bus/features/alerts/view/notification_sheet.dart';

import '../../../support/helpers/i18n.dart';
import '../../../support/helpers/in_memory_settings_store.dart';

AlertRepository _repo() => AlertRepository(
  settings: SettingsRepository(store: InMemorySettingsStore(const {})),
);

void main() {
  testWidgets('row shows source chip, relative time, and expands to footer', (
    tester,
  ) async {
    final bloc = AlertBloc(repository: _repo());
    addTearDown(bloc.close);

    const source = AlertSource(AlertSourceKind.metro, 'TRTC');
    final alert = AlertViewModel(
      message: '因號誌故障,各站班距拉長',
      level: AlertSeverity.red,
      title: '中和新蘆線延誤',
      time: DateTime.now(),
      source: source,
    );
    bloc.add(AlertReceived(source, [alert]));
    await bloc.stream.first;

    await tester.pumpWidget(
      i18nApp(
        BlocProvider.value(
          value: bloc,
          child: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showNotificationSheet(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Meta row: operator chip + relative time.
    expect(find.text('北捷'), findsOneWidget);
    expect(find.text('剛剛'), findsOneWidget);
    expect(find.text('中和新蘆線延誤'), findsOneWidget);

    // Collapsed: no publish footer yet.
    expect(find.textContaining('發布'), findsNothing);

    // Tapping the row expands it to reveal the publish footer.
    await tester.tap(find.text('中和新蘆線延誤'));
    await tester.pumpAndSettle();
    expect(find.textContaining('發布'), findsOneWidget);
  });
}

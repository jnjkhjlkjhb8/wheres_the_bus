import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/rail_system_labels.dart';
import 'package:wheres_the_bus/shared/widgets/app_date_picker.dart';
import 'package:wheres_the_bus/shared/widgets/app_spinner.dart';
import 'package:wheres_the_bus/shared/widgets/app_time_picker.dart';
import 'package:wheres_the_bus/shared/widgets/clock_dial.dart';
import 'package:wheres_the_bus/shared/widgets/state_cards.dart';
import 'package:wheres_the_bus/shared/widgets/thsr_station_picker.dart';

Widget host(Widget child) => MaterialApp(
  theme: AppTheme.light,
  locale: const Locale('zh', 'TW'),
  localizationsDelegates: AppI18n.localizationsDelegates,
  supportedLocales: AppI18n.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);

Widget launcher(VoidCallback Function(BuildContext) action) => host(
  Builder(
    builder: (context) => ElevatedButton(
      onPressed: action(context),
      child: const Text('open'),
    ),
  ),
);

void main() {
  testWidgets(
    'calendar clamps old and future selections without selecting them',
    (tester) async {
      final first = DateTime(2026, 10);
      final last = DateTime(2026, 10, 31);
      DateTime? selected;
      for (final day in [DateTime(2025), DateTime(2027), null]) {
        await tester.pumpWidget(
          host(
            AppDatePicker(
              selectedDay: day,
              firstDay: first,
              lastDay: last,
              onDaySelected: (value) => selected = value,
            ),
          ),
        );
        final calendar = tester.widget<TableCalendar<Object>>(
          find.byType(TableCalendar<Object>),
        );
        expect(calendar.focusedDay.year, 2026);
        expect(calendar.focusedDay.month, 10);
        if (day != null) {
          expect(
            isSameDay(calendar.focusedDay, day.year == 2025 ? first : last),
            isTrue,
          );
        }
        expect(calendar.selectedDayPredicate!(DateTime(2026, 10, 15)), isFalse);
        await tester.tap(find.text('15').first);
        await tester.pumpAndSettle();
        expect(isSameDay(selected, DateTime(2026, 10, 15)), isTrue);
      }
      await tester.pumpWidget(
        host(
          AppDatePicker(
            selectedDay: DateTime(2026, 10, 15),
            onDaySelected: (_) {},
          ),
        ),
      );
      final calendar = tester.widget<TableCalendar<Object>>(
        find.byType(TableCalendar<Object>),
      );
      expect(calendar.selectedDayPredicate!(DateTime(2026, 10, 15)), isTrue);
      expect(calendar.selectedDayPredicate!(DateTime(2026, 10, 16)), isFalse);
    },
  );

  testWidgets('time picker confirms the wheel value and cancels changes', (
    tester,
  ) async {
    TimeOfDay? result;
    await tester.pumpWidget(
      launcher(
        (context) => () async {
          result = await AppTimePicker.show(
            context,
            const TimeOfDay(hour: 8, minute: 5),
          );
        },
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final wheel = tester.widget<CupertinoDatePicker>(
      find.byType(CupertinoDatePicker),
    );
    expect(wheel.use24hFormat, isTrue);
    expect(wheel.initialDateTime.hour, 8);
    expect(wheel.initialDateTime.minute, 5);
    wheel.onDateTimeChanged(DateTime(2026, 10, 10, 12, 35));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(result, const TimeOfDay(hour: 12, minute: 35));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    tester
        .widget<CupertinoDatePicker>(find.byType(CupertinoDatePicker))
        .onDateTimeChanged(DateTime(2026, 10, 10, 15));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('THSR picker returns the chosen station or cancellation', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      launcher(
        (context) => () async {
          result = await showTHSRStationPicker(context);
        },
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.widget<ClockDial>(find.byType(ClockDial)).selectedIndex, 1);
    await tester.tapAt(tester.getCenter(find.text('左營')));
    await tester.pumpAndSettle();
    expect(tester.widget<ClockDial>(find.byType(ClockDial)).selectedIndex, 11);
    await tester.tap(find.text('確定'));
    await tester.pumpAndSettle();
    expect(result, '左營');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('loading and empty/error states expose copy and retry action', (
    tester,
  ) async {
    await tester.pumpWidget(host(const AppSpinner()));
    expect(tester.getSize(find.byType(AppSpinner)), const Size(24, 24));
    var spinner = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(spinner.color, AppTheme.light.colorScheme.primary);
    expect(spinner.strokeWidth, 2.5);
    await tester.pumpWidget(
      host(const AppSpinner(size: 40, color: Colors.red, strokeWidth: 4)),
    );
    spinner = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(spinner.color, Colors.red);
    expect(spinner.strokeWidth, 4);
    expect(tester.getSize(find.byType(AppSpinner)), const Size(40, 40));
    await tester.pumpWidget(host(const EmptyStateCard(message: 'empty')));
    expect(find.text('empty'), findsOneWidget);
    expect(find.byIcon(Icons.inbox_rounded), findsOneWidget);
    await tester.pumpWidget(
      host(const EmptyStateCard(message: 'none', icon: Icons.train)),
    );
    expect(find.byIcon(Icons.train), findsOneWidget);
    await tester.pumpWidget(host(const ErrorStateCard(message: 'failed')));
    expect(find.text('failed'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    var retries = 0;
    await tester.pumpWidget(
      host(ErrorStateCard(message: 'retry', onRetry: () => retries++)),
    );
    await tester.tap(find.byType(FilledButton));
    expect(retries, 1);
  });

  test('rail labels preserve TRA fallback for unknown saved subtitles', () {
    expect(railSystemLabel(RailSystem.tra), '台鐵');
    expect(railSystemLabel(RailSystem.thsr), '高鐵');
    expect(railSystemFromLabel('高鐵'), RailSystem.thsr);
    expect(railSystemFromLabel('台鐵'), RailSystem.tra);
    expect(railSystemFromLabel(''), RailSystem.tra);
    expect(railSystemFromLabel('legacy'), RailSystem.tra);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:wheres_the_bus/shared/widgets/app_date_picker.dart';

import '../../support/helpers/i18n.dart';

void main() {
  testWidgets('defaults to a window one year either side of today', (
    tester,
  ) async {
    await tester.pumpWidget(
      i18nApp(
        Scaffold(
          body: AppDatePicker(selectedDay: null, onDaySelected: (_) {}),
        ),
      ),
    );
    final year = DateTime.now().year;
    final calendar = tester.widget<TableCalendar<Object>>(
      find.byType(TableCalendar<Object>),
    );
    expect(calendar.firstDay.year, year - 1);
    expect(calendar.lastDay.year, year + 1);
  });

  testWidgets('explicit bounds win and a stray selection is clamped', (
    tester,
  ) async {
    final first = DateTime(2026, 8);
    final last = DateTime(2026, 9, 30);
    await tester.pumpWidget(
      i18nApp(
        Scaffold(
          body: AppDatePicker(
            selectedDay: DateTime(2030),
            firstDay: first,
            lastDay: last,
            onDaySelected: (_) {},
          ),
        ),
      ),
    );
    final calendar = tester.widget<TableCalendar<Object>>(
      find.byType(TableCalendar<Object>),
    );
    // TableCalendar normalizes every day it is given to UTC midnight.
    expect(calendar.firstDay, DateTime.utc(2026, 8));
    expect(calendar.lastDay, DateTime.utc(2026, 9, 30));
    expect(calendar.focusedDay, DateTime.utc(2026, 9, 30));
  });

  testWidgets('a selection before the window clamps to the first day', (
    tester,
  ) async {
    final first = DateTime(2026, 8);
    await tester.pumpWidget(
      i18nApp(
        Scaffold(
          body: AppDatePicker(
            selectedDay: DateTime(2020),
            firstDay: first,
            lastDay: DateTime(2026, 9, 30),
            onDaySelected: (_) {},
          ),
        ),
      ),
    );
    final calendar = tester.widget<TableCalendar<Object>>(
      find.byType(TableCalendar<Object>),
    );
    expect(calendar.focusedDay, DateTime.utc(2026, 8));
  });
}

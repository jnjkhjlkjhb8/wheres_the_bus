import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/shared/widgets/app_date_picker.dart';

import '../../support/helpers/i18n.dart';

void main() {
  final first = DateTime(2026, 8);
  final last = DateTime(2026, 9, 30);

  Future<TableCalendar<Object>> mount(
    WidgetTester tester, {
    DateTime? selected,
    ValueChanged<DateTime>? onSelected,
  }) async {
    await tester.pumpWidget(
      i18nApp(
        Scaffold(
          body: AppDatePicker(
            selectedDay: selected,
            firstDay: first,
            lastDay: last,
            onDaySelected: onSelected ?? (_) {},
          ),
        ),
      ),
    );
    return tester.widget<TableCalendar<Object>>(
      find.byType(TableCalendar<Object>),
    );
  }

  testWidgets('a selection inside the window is the focused month', (
    tester,
  ) async {
    final calendar = await mount(tester, selected: DateTime(2026, 9, 12));
    expect(isSameDay(calendar.focusedDay, DateTime(2026, 9, 12)), isTrue);
    expect(calendar.selectedDayPredicate!(DateTime(2026, 9, 12)), isTrue);
  });

  testWidgets('only the selected day reads as selected', (tester) async {
    final calendar = await mount(tester, selected: DateTime(2026, 9, 12));
    expect(calendar.selectedDayPredicate!(DateTime(2026, 9, 13)), isFalse);
    expect(calendar.selectedDayPredicate!(DateTime(2026, 8, 12)), isFalse);
  });

  testWidgets('with no selection nothing reads as selected', (tester) async {
    final calendar = await mount(tester);
    for (final day in [DateTime(2026, 8, 5), DateTime.now()]) {
      expect(calendar.selectedDayPredicate!(day), isFalse);
    }
  });

  testWidgets('with no selection the calendar opens on today, kept in range', (
    tester,
  ) async {
    final calendar = await mount(tester);
    final now = DateTime.now();
    final expected = now.isBefore(first)
        ? first
        : now.isAfter(last)
        ? last
        : now;
    // table_calendar normalizes focusedDay to a UTC date, so compare days.
    expect(isSameDay(calendar.focusedDay, expected), isTrue);
  });

  testWidgets('tapping a day reports that day once', (tester) async {
    final picked = <DateTime>[];
    await mount(
      tester,
      selected: DateTime(2026, 8, 10),
      onSelected: picked.add,
    );
    await tester.tap(find.text('20').first);
    await tester.pump();
    expect(picked, hasLength(1));
    expect(
      (picked.single.year, picked.single.month, picked.single.day),
      (2026, 8, 20),
    );
  });

  testWidgets('shows a month view without a format switch', (tester) async {
    final calendar = await mount(tester);
    expect(calendar.availableCalendarFormats, const {CalendarFormat.month: ''});
    expect(calendar.headerStyle.formatButtonVisible, isFalse);
    expect(calendar.headerStyle.titleCentered, isTrue);
    expect(calendar.headerStyle.titleTextStyle.fontWeight, FontWeight.w600);
    expect(
      calendar.headerStyle.titleTextStyle.fontSize,
      AppTextStyles.bodyRegular.fontSize,
    );
  });

  testWidgets('colours follow the scheme', (tester) async {
    final calendar = await mount(tester, selected: DateTime(2026, 8, 10));
    final scheme = Theme.of(
      tester.element(find.byType(AppDatePicker)),
    ).colorScheme;
    final style = calendar.calendarStyle;
    expect((style.selectedDecoration as BoxDecoration).color, scheme.primary);
    expect((style.selectedDecoration as BoxDecoration).shape, BoxShape.circle);
    expect(style.selectedTextStyle.color, scheme.onPrimary);
    expect(
      (style.todayDecoration as BoxDecoration).color,
      scheme.primaryContainer,
    );
    expect((style.todayDecoration as BoxDecoration).shape, BoxShape.circle);
    expect(style.todayTextStyle.color, scheme.onPrimaryContainer);
    expect(style.weekendTextStyle.color, scheme.error);
    expect(style.outsideTextStyle.color, scheme.onSurfaceVariant);
    expect(style.defaultTextStyle.fontSize, AppTextStyles.bodySmall.fontSize);
    expect(
      calendar.daysOfWeekStyle.weekdayStyle.color,
      scheme.onSurfaceVariant,
    );
    expect(calendar.daysOfWeekStyle.weekendStyle.color, scheme.error);
    expect(
      (calendar.headerStyle.leftChevronIcon as Icon).icon,
      Icons.chevron_left_rounded,
    );
    expect(
      (calendar.headerStyle.leftChevronIcon as Icon).color,
      scheme.onSurface,
    );
    expect(
      (calendar.headerStyle.rightChevronIcon as Icon).icon,
      Icons.chevron_right_rounded,
    );
    expect(
      (calendar.headerStyle.rightChevronIcon as Icon).color,
      scheme.onSurface,
    );
  });
}

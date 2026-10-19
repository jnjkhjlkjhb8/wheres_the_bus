import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_state.dart';
import 'package:wheres_the_bus/features/rail/view/rail_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

class _Rail extends RailBloc {
  _Rail() {
    emit(
      const RailTimetableLoading(
        system: RailSystem.tra,
        originName: '台北',
        destName: '台中',
        date: '2030-01-02',
      ),
    );
  }
  @override
  void add(RailEvent event) {}
}

void main() {
  testWidgets('loading timetable shows seven skeleton rows split by dividers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bloc = _Rail();
    addTearDown(bloc.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: RailScreen(bloc: bloc, clock: () => DateTime(2030, 1, 2, 8)),
      ),
    );
    await tester.pump();

    final scheme = Theme.of(
      tester.element(find.byType(Divider).first),
    ).colorScheme;
    final rowDividers = tester
        .widgetList<Divider>(find.byType(Divider))
        .where(
          (d) =>
              d.height == 1 &&
              d.thickness == 1 &&
              d.indent == 16 &&
              d.color == scheme.outlineVariant.withValues(alpha: 0.4),
        );
    expect(rowDividers, hasLength(6));
    expect(find.text('000'), findsNWidgets(7));
  });
}

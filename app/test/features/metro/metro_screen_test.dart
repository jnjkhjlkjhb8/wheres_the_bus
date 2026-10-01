import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_bloc.dart';
import 'package:wheres_the_bus/features/metro/view/metro_screen.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

void main() {
  testWidgets('metro sheet no longer hosts the time/fare sliding segment', (
    tester,
  ) async {
    final favorites = FavoritesBloc(
      _FakeFavoritesRepository(),
      ValueNotifier(true),
    );
    addTearDown(favorites.close);

    // The map hosts the 下車提醒 pick now, so it reads the session bloc the
    // same way the app shell provides it. Never fed an event here, so it does
    // no I/O.
    late final MrtTrackBloc track;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,

        theme: AppTheme.light,
        home: Builder(
          builder: (context) {
            track = MrtTrackBloc(i18n: AppI18n.of(context));
            addTearDown(track.close);
            return MultiBlocProvider(
              providers: [
                BlocProvider<FavoritesBloc>.value(value: favorites),
                BlocProvider<MrtTrackBloc>.value(value: track),
              ],
              child: const MetroScreen(),
            );
          },
        ),
      ),
    );
    await tester.pump();

    // The mode switch moved to a floating map chip that only appears once a
    // station is selected; nothing about it sits atop the sheet any more.
    // '旅途時間' is the switch's own label and is unique to it.
    expect(find.text('旅途時間'), findsNothing);
  });
}

class _FakeFavoritesRepository implements FavoritesRepository {
  @override
  bool get isReady => true;

  @override
  Stream<BoxEvent> watch() => const Stream.empty();

  @override
  Stream<void> changes() => const Stream.empty();

  @override
  List<Favorite> all() => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

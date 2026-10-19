import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_bloc.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

class EmptyFavoritesRepository implements FavoritesRepository {
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

/// Pumps [child] under the providers the metro sheets read in production.
/// Returns the track bloc so tests can drive or inspect it.
Future<MrtTrackBloc> pumpWithMetroProviders(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(430, 900),
  MrtTrackBloc? track,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final favorites = FavoritesBloc(
    EmptyFavoritesRepository(),
    ValueNotifier(true),
  );
  addTearDown(favorites.close);
  late final MrtTrackBloc bloc;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('zh'),
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      home: Builder(
        builder: (context) {
          bloc = track ?? MrtTrackBloc(i18n: AppI18n.of(context));
          if (track == null) addTearDown(bloc.close);
          return MultiBlocProvider(
            providers: [
              BlocProvider<FavoritesBloc>.value(value: favorites),
              BlocProvider<MrtTrackBloc>.value(value: bloc),
            ],
            child: Scaffold(body: child),
          );
        },
      ),
    ),
  );
  return bloc;
}

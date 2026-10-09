import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/metro/view/metro_screen.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  setUpAll(HiveStore.init);

  testWidgets('metro map pan performance', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: BlocProvider(
          create: (_) =>
              FavoritesBloc(FavoritesRepository.instance, ValueNotifier(true)),
          child: const MetroScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final map = find.byType(InteractiveViewer);
    expect(map, findsOneWidget);

    await binding.watchPerformance(() async {
      for (var i = 0; i < 6; i++) {
        await tester.timedDrag(
          map,
          const Offset(0, -350),
          const Duration(milliseconds: 400),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.timedDrag(
          map,
          const Offset(0, 350),
          const Duration(milliseconds: 400),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
    }, reportKey: 'metro_pan');
  });
}

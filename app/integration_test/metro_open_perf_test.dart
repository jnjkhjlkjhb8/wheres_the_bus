import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/metro/view/metro_screen.dart';
import 'package:wheres_the_bus/features/metro/widgets/metro_svg_map.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  setUpAll(HiveStore.init);

  testWidgets('metro screen cold open performance', (tester) async {
    await tester.pumpWidget(
      BlocProvider(
        create: (_) =>
            FavoritesBloc(FavoritesRepository.instance, ValueNotifier(true)),
        child: MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const MetroScreen(),
                    ),
                  ),
                  child: const Text('open metro'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Mirror HomeScreen: precache the map bitmap, then idle as a user would.
    final host = tester.element(find.text('open metro'));
    MetroSvgMap.precache(host);
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    Future<void> openAndWatch(String key) => binding.watchPerformance(() async {
      await tester.tap(find.text('open metro'));
      // Let the push transition and first map frames play out in real time.
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }, reportKey: key);

    await openAndWatch('metro_open_cold');

    // Pop back and reopen: a clean second run means the remaining first-open
    // cost is session-once engine work (shader compilation, font loading).
    await tester.pageBack();
    await tester.pumpAndSettle();
    await openAndWatch('metro_open_warm');
  });
}

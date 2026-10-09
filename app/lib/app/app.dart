import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:wheres_the_bus/app/router/app_router.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/bootstrap/app_bootstrap.dart';
import 'package:wheres_the_bus/core/lifecycle/app_foreground.dart';
import 'package:wheres_the_bus/core/lifecycle/app_network.dart';
import 'package:wheres_the_bus/core/live_activity/alight_track.dart';
import 'package:wheres_the_bus/core/live_activity/alight_track_inbound_channel.dart';
import 'package:wheres_the_bus/core/location/location_service.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/core/update/update_gate.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_bloc.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_event.dart';
import 'package:wheres_the_bus/data/tracking/journey_session_state.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_event.dart';
import 'package:wheres_the_bus/features/alerts/view/notification_toast.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_bloc.dart';
import 'package:wheres_the_bus/features/metro/bloc/mrt_track_event.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/map/marker_factory.dart';

// the floor must never double as a ceiling — it must not silently roll
// back a larger system-level accessibility preference. Keep this
// clamp-min-only; any max clamp lives in a separate step (see

class App extends StatefulWidget {
  const App({required this.bootstrap, this.debugRouter, super.key});

  final AppBootstrapController bootstrap;

  @visibleForTesting
  final GoRouter? debugRouter;

  /// Tracks background initialization completion
  static final isInitialized = ValueNotifier<bool>(false);

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  @override
  void initState() {
    super.initState();
    AppForeground.start();
    AppNetwork.start();
    widget.bootstrap.addListener(_syncInitialized);
    _syncInitialized();
  }

  @override
  void dispose() {
    widget.bootstrap.removeListener(_syncInitialized);
    super.dispose();
  }

  void _syncInitialized() {
    final ready =
        widget.bootstrap.state == AppBootstrapState.ready ||
        widget.bootstrap.state == AppBootstrapState.degraded;
    if (App.isInitialized.value != ready) {
      App.isInitialized.value = ready;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.bootstrap,
      builder: (context, _) {
        switch (widget.bootstrap.state) {
          case AppBootstrapState.initializing:
            return const _BootstrapGateApp(child: _BootstrapSplash());
          case AppBootstrapState.failed:
            return _BootstrapGateApp(
              child: _BootstrapFailedView(
                phase: widget.bootstrap.lastErrorPhase,
                onRetry: widget.bootstrap.retry,
              ),
            );
          case AppBootstrapState.ready:
          case AppBootstrapState.degraded:
            return _AppShell(router: widget.debugRouter);
        }
      },
    );
  }
}

/// Minimal `MaterialApp` for the splash/failed states — no router, no
/// providers, so it never touches Hive/location/gRPC-backed singletons
/// before the essential path has actually settled.
class _BootstrapGateApp extends StatelessWidget {
  const _BootstrapGateApp({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppI18n.of(context).appTitle,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      localizationsDelegates: AppI18n.localizationsDelegates,
      supportedLocales: AppI18n.supportedLocales,
      debugShowCheckedModeBanner: false,
      home: child,
    );
  }
}

class _BootstrapSplash extends StatelessWidget {
  const _BootstrapSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: AppTheme.inkLight,
          ),
        ),
      ),
    );
  }
}

/// Shown when an essential dependency (local storage or the gRPC channel
/// config) failed to initialize. No router/providers are mounted behind
/// this — the app cannot safely proceed until [onRetry] succeeds.
class _BootstrapFailedView extends StatelessWidget {
  const _BootstrapFailedView({required this.phase, required this.onRetry});

  final AppBootstrapFailurePhase? phase;
  final VoidCallback onRetry;

  String _message(AppI18n i18n) => switch (phase) {
    AppBootstrapFailurePhase.storage => i18n.bootstrapFailedStorage,
    AppBootstrapFailurePhase.network => i18n.bootstrapFailedNetwork,
    null => i18n.bootstrapFailedUnknown,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.space32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 40,
                  color: AppTheme.inkLight,
                ),
                const SizedBox(height: AppTheme.space16),
                Text(
                  _message(AppI18n.of(context)),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15, color: Colors.black87),
                ),
                const SizedBox(height: AppTheme.space24),
                FilledButton(
                  key: const Key('bootstrapRetryButton'),
                  onPressed: onRetry,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.inkLight,
                  ),
                  child: Text(AppI18n.of(context).commonRetry),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The full app: providers, router, alerts. Only ever built once bootstrap
/// is `ready` or `degraded` (see `_AppState.build`).
class _AppShell extends StatelessWidget {
  const _AppShell({this.router});

  final GoRouter? router;

  @override
  Widget build(BuildContext context) {
    // Shared across JourneySessionBloc and MrtTrackBloc: only one tracking
    // card can exist, so both drivers must target the same channel.
    final liveActivityChannel = AlightTrackChannel();
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => AlertBloc()),
        BlocProvider(create: (_) => PlanBloc()),
        BlocProvider(
          create: (_) {
            // iOS drives the Live Activity / Dynamic Island; Android drives
            // the promoted Live Update notification + status-bar chip
            // (supersedes spec 決策 3, which kept Android on PiP only).
            final bloc = JourneySessionBloc(
              channel: liveActivityChannel,
              positions: LocationService.instance.navigationStream,
            );
            AlightTrackInboundChannel.bind(() {
              if (bloc.state.phase == JourneyPhase.idle) return;
              bloc.add(const JourneyCancelled(userInitiated: true));
            });
            return bloc;
          },
        ),
        BlocProvider(
          create: (_) {
            final bloc = MrtTrackBloc(
              i18n: lookupAppI18n(
                SettingsRepository.instance.locale ??
                    basicLocaleListResolution(
                      WidgetsBinding.instance.platformDispatcher.locales,
                      AppI18n.supportedLocales,
                    ),
              ),
              channel: liveActivityChannel,
            )..add(const MrtTrackRestored());
            // Tracking card 取消追蹤 action → CancelTrack, but only while this
            // bloc is the one holding the card (see the journey binding above).
            AlightTrackInboundChannel.bind(() {
              if (bloc.state.session == null) return;
              bloc.add(const MrtTrackCancelled());
            });
            AlightTrackInboundChannel.bindPushToken(
              (token) => bloc.add(MrtTrackPushTokenReceived(token)),
            );
            return bloc;
          },
        ),
        BlocProvider(
          create: (_) =>
              FavoritesBloc(FavoritesRepository.instance, App.isInitialized),
        ),
      ],
      child: _AppShellView(router: router),
    );
  }
}

class _AppShellView extends StatefulWidget {
  const _AppShellView({this.router});

  final GoRouter? router;

  @override
  State<_AppShellView> createState() => _AppShellViewState();
}

class _AppShellViewState extends State<_AppShellView> {
  // Cancellable so a shell disposed before the delay elapses (tests, hot
  // restart) doesn't leave a pending timer behind.
  Timer? _alertStartTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Delayed so the alert streams (TRA/THSR gRPC + Remote Config) don't
      // compete with home's first interactive frame.
      _alertStartTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted) return;
        context.read<AlertBloc>().add(const AlertStarted());
      });
    });
  }

  @override
  void dispose() {
    _alertStartTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Box<dynamic>>(
      valueListenable: HiveStore.settings.listenable(
        keys: const [
          'large_text',
          'appearance_mode',
          SettingsRepository.languageKey,
        ],
      ),
      builder: (context, _, child) => MaterialApp.router(
        onGenerateTitle: (context) => AppI18n.of(context).appTitle,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: SettingsRepository.instance.themeMode,
        // Null for the 'system' preference, which is what hands resolution
        // back to the device's locale list.
        locale: SettingsRepository.instance.locale,
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        routerConfig: widget.router ?? AppRouter.router,
        // Pairs with the router's own scope id: together they let Android
        // rebuild the navigation stack after killing the process, instead of
        // returning a rider who switched apps mid-journey to the home screen.
        restorationScopeId: 'app',
        debugShowCheckedModeBanner: false,
        builder: (context, child) {
          final base = child!;
          MapMarkers.configure(
            devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
            textScaler: MediaQuery.textScalerOf(context),
          );
          // Reduce-motion swaps the shimmer sweep for a flat fill: the
          // skeleton still says "this is content, not chrome" without a
          // moving highlight. One override for every skeleton in the app.
          final theme = Theme.of(context);
          final skeleton = theme.extension<SkeletonizerConfigData>();
          final gated = UpdateGate(child: NotificationToastHost(child: base));
          if (skeleton == null || !MediaQuery.disableAnimationsOf(context)) {
            return gated;
          }
          return SkeletonizerConfig(
            data: skeleton.copyWith(
              effect: SolidColorEffect(
                color: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            child: gated,
          );
        },
      ),
    );
  }
}

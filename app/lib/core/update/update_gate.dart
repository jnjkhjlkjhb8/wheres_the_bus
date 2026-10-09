import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/firebase/remote_config.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/core/update/update_status.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

final availableUpdate = ValueNotifier<String?>(null);

class UpdateGate extends StatefulWidget {
  const UpdateGate({
    required this.child,
    super.key,
    this.revisions,
    this.minVersionOf,
    this.latestVersionOf,
    this.dismissedVersionOf,
    this.maintenanceOf,
  });

  final Widget child;

  /// Injectable for tests; defaults to [AppConfig.revisions()].
  final Stream<void>? revisions;

  /// Injectable for tests; defaults to reading `min_supported_version` from
  /// [AppConfig].
  final String Function()? minVersionOf;

  /// Injectable for tests; defaults to reading `latest_version`.
  final String Function()? latestVersionOf;

  /// Injectable for tests; defaults to the persisted dismissal.
  final String? Function()? dismissedVersionOf;

  /// Injectable for tests; defaults to reading the maintenance keys.
  final ({bool enabled, String message}) Function()? maintenanceOf;

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  String? _blockedAt;
  String? _maintenance;
  StreamSubscription<void>? _revisionSub;

  String get _minVersion =>
      (widget.minVersionOf ??
      () => AppConfig.getString('min_supported_version'))();

  String get _latestVersion =>
      (widget.latestVersionOf ?? () => AppConfig.getString('latest_version'))();

  String? get _dismissedVersion =>
      (widget.dismissedVersionOf ?? () => HiveStore.dismissedUpdateVersion)();

  ({bool enabled, String message}) get _maintenanceConfig =>
      (widget.maintenanceOf ??
      () => (
        enabled: AppConfig.getBool('maintenance_banner_enabled'),
        message: AppConfig.getString('maintenance_banner_text'),
      ))();

  @override
  void initState() {
    super.initState();
    unawaited(_check());
    _revisionSub = (widget.revisions ?? AppConfig.revisions()).listen(
      (_) => unawaited(_check()),
    );
  }

  @override
  void dispose() {
    unawaited(_revisionSub?.cancel());
    super.dispose();
  }

  Future<void> _check() async {
    try {
      final maintenance = _maintenanceConfig;
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(
        () => _maintenance = maintenance.enabled ? maintenance.message : null,
      );
      final latest = _latestVersion;
      switch (resolveUpdateStatus(
        current: info.version,
        minSupported: _minVersion,
        latest: latest,
      )) {
        case UpdateStatus.blocked:
          availableUpdate.value = null;
          setState(() => _blockedAt = info.version);
        case UpdateStatus.available:
          // A dismissal only covers the exact version it was made against, so
          // a newer release re-arms the nudge on its own.
          availableUpdate.value = _dismissedVersion == latest ? null : latest;
        case UpdateStatus.upToDate:
          availableUpdate.value = null;
      }
    } on Object catch (_) {
      // Fail open: any failure reading the version leaves the app usable.
    }
  }

  @override
  Widget build(BuildContext context) {
    final maintenance = _maintenance;
    if (maintenance != null) return _MaintenanceScreen(message: maintenance);
    final blocked = _blockedAt;
    return blocked == null ? widget.child : _ForceUpdateScreen(blocked);
  }
}

class _BlockingScreen extends StatelessWidget {
  const _BlockingScreen({
    required this.icon,
    required this.title,
    required this.body,
    this.detail,
    this.footer,
  });

  final IconData icon;
  final String title;
  final String body;

  /// Mono line under the body — versions and other figures. Null when there
  /// is no figure to state.
  final String? detail;

  /// Pinned to the bottom. Null for a dead end with nothing to do, which is
  /// what a maintenance window is: waiting is the only move.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final detailLine = detail;

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.space24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(flex: 2),
                Icon(icon, size: 32, color: cs.onSurfaceVariant),
                const SizedBox(height: AppTheme.space24),
                Text(title, style: AppTextStyles.heading1),
                const SizedBox(height: AppTheme.space12),
                Text(
                  body,
                  style: AppTextStyles.bodyLarge.copyWith(
                    color: cs.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                if (detailLine != null) ...[
                  const SizedBox(height: AppTheme.space20),
                  // Versions are data, so they render in mono like every other
                  // figure in the app.
                  Text(
                    detailLine,
                    style: AppTextStyles.memo.copyWith(color: cs.outline),
                  ),
                ],
                const Spacer(flex: 3),
                ?footer,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MaintenanceScreen extends StatelessWidget {
  const _MaintenanceScreen({required this.message});

  /// Ops-authored copy from Remote Config. Empty when ops opened the window
  /// without writing anything, which the fallback covers.
  final String message;

  @override
  Widget build(BuildContext context) => _BlockingScreen(
    icon: Icons.build_rounded,
    title: AppI18n.of(context).maintenanceTitle,
    body: message.isEmpty ? AppI18n.of(context).maintenanceBody : message,
  );
}

/// Blocking interstitial for an unsupported build.
class _ForceUpdateScreen extends StatelessWidget {
  const _ForceUpdateScreen(this.currentVersion);

  final String currentVersion;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final minVersion = AppConfig.getString('min_supported_version');
    // Only render the direct-open button for a URL that passes the allowlist
    // (F44); anything else falls back to the "search the store" copy instead
    // of a button that silently no-ops on tap.
    final url = storeUrl();

    return _BlockingScreen(
      icon: Icons.system_update_rounded,
      title: AppI18n.of(context).updateRequiredTitle,
      body: AppI18n.of(context).updateRequiredBody,
      detail: AppI18n.of(context).updateVersionLine(currentVersion, minVersion),
      footer: url != null
          ? FilledButton(
              onPressed: () =>
                  launchUrl(url, mode: LaunchMode.externalApplication),
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 50),
              ),
              child: Text(AppI18n.of(context).settingsUpdateGo),
            )
          : Text(
              Platform.isIOS
                  ? AppI18n.of(context).updateStoreHintIos
                  : AppI18n.of(context).updateStoreHintAndroid,
              style: AppTextStyles.bodyRegular.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
    );
  }
}

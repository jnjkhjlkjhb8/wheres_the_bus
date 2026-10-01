import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/core/haptics/haptic_service.dart';
import 'package:wheres_the_bus/core/live_activity/alight_track.dart';
import 'package:wheres_the_bus/core/update/update_status.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/settings/bloc/settings_bloc.dart';
import 'package:wheres_the_bus/features/settings/bloc/settings_event.dart';
import 'package:wheres_the_bus/features/settings/bloc/settings_state.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_switch.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    this.updatePushPreference,
    this.settings,
    this.packageInfoLoader,
    this.lastSyncedAtOf,
    this.refreshConfig,
    this.latestVersionOf,
  });

  final PushUpdater? updatePushPreference;

  /// Injectable for tests; defaults to the shared repository instance.
  final SettingsRepository? settings;

  /// Injectable for tests; forwarded to [SettingsBloc].
  final Future<PackageInfo> Function()? packageInfoLoader;

  /// Injectable for tests; forwarded to [SettingsBloc].
  final DateTime? Function()? lastSyncedAtOf;

  /// Injectable for tests; forwarded to [SettingsBloc].
  final Future<bool> Function()? refreshConfig;

  /// Injectable for tests; forwarded to [SettingsBloc].
  final String Function()? latestVersionOf;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => SettingsBloc(
        settings: settings,
        updatePushPreference: updatePushPreference,
        packageInfoLoader: packageInfoLoader,
        lastSyncedAtOf: lastSyncedAtOf,
        refreshConfig: refreshConfig,
        latestVersionOf: latestVersionOf,
      ),
      child: const _SettingsView(),
    );
  }
}

String formatSyncFreshness(AppI18n i18n, DateTime? dt) {
  if (dt == null) return i18n.settingsSyncNever;
  final local = dt.toLocal();
  final now = DateTime.now();
  final isToday =
      local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  final time = DateFormat('HH:mm').format(local);
  return isToday
      ? i18n.settingsSyncToday(time)
      : '${DateFormat('MM/dd').format(local)} $time';
}

class _SettingsView extends StatelessWidget {
  const _SettingsView();

  /// Runs the shared single-choice picker screen over [values], which the
  /// picker identifies by label rather than by enum — so every label is
  /// resolved once, here, against the locale in force when the sheet opens.
  Future<T?> _pick<T>(
    BuildContext context,
    String route,
    List<T> values,
    T current,
    String Function(T) labelOf,
  ) async {
    final result = await context.push<String>(
      route,
      extra: {
        'options': [for (final v in values) labelOf(v)],
        'selected': labelOf(current),
      },
    );
    if (result == null || !context.mounted) return null;
    return values.firstWhere(
      (v) => labelOf(v) == result,
      orElse: () => current,
    );
  }

  Future<void> _pickAppearance(
    BuildContext context,
    AppI18n i18n,
    Appearance current,
  ) async {
    final picked = await _pick(
      context,
      AppRoutes.settingsAppearance,
      Appearance.values,
      current,
      (e) => e.labelOf(i18n),
    );
    if (picked != null && context.mounted) {
      context.read<SettingsBloc>().add(AppearanceSelected(picked));
    }
  }

  /// Picks the app's language. The choice writes through to the settings box,
  /// which the root app listens on, so the whole UI re-renders in the new
  /// locale without a restart.
  Future<void> _pickLanguage(
    BuildContext context,
    AppI18n i18n,
    Language current,
  ) async {
    final picked = await _pick(
      context,
      AppRoutes.settingsLanguage,
      Language.values,
      current,
      (e) => e.labelOf(i18n),
    );
    if (picked != null && context.mounted) {
      context.read<SettingsBloc>().add(LanguageSelected(picked));
    }
  }

  /// Picks the rider's usual walking pace, applied to every plan.
  Future<void> _pickWalkPace(
    BuildContext context,
    AppI18n i18n,
    WalkPace current,
  ) async {
    final picked = await _pick(
      context,
      AppRoutes.settingsWalkPace,
      WalkPace.values,
      current,
      (e) => e.labelOf(i18n),
    );
    if (picked != null && context.mounted) {
      context.read<SettingsBloc>().add(WalkPaceSelected(picked));
    }
  }

  /// Picks the rider's ticket type, on the shared single-choice picker screen.
  Future<void> _pickFareType(
    BuildContext context,
    AppI18n i18n,
    FareType current,
  ) async {
    final picked = await _pick(
      context,
      AppRoutes.settingsFareType,
      FareType.values,
      current,
      (e) => e.labelOf(i18n),
    );
    if (picked != null && context.mounted) {
      context.read<SettingsBloc>().add(FareTypeSelected(picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SettingsBloc, SettingsState>(builder: _buildBody);
  }

  Widget _buildBody(BuildContext context, SettingsState state) {
    final bloc = context.read<SettingsBloc>();
    final i18n = AppI18n.of(context);
    final topPadding = MediaQuery.paddingOf(context).top;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: _LargeTitleHeader(
              title: i18n.settingsTitle,
              topPadding: topPadding,
              reduceMotion: reduceMotion,
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              AppTheme.space16,
              AppTheme.space8,
              AppTheme.space16,
              bottomInset + AppTheme.space32,
            ),
            sliver: SliverList.list(
              children: [
                _SettingsSection(
                  title: i18n.settingsSectionAppearance,
                  children: [
                    _SettingsRow(
                      icon: Icons.dark_mode_outlined,
                      label: i18n.settingsAppearance,
                      value: state.appearance.labelOf(i18n),
                      chevron: true,
                      onTap: () =>
                          _pickAppearance(context, i18n, state.appearance),
                    ),
                    _SettingsRow(
                      icon: Icons.language_rounded,
                      label: i18n.settingsLanguage,
                      value: state.language.labelOf(i18n),
                      chevron: true,
                      onTap: () => _pickLanguage(context, i18n, state.language),
                    ),
                    _SettingsSwitchRow(
                      icon: Icons.notifications_none_rounded,
                      label: i18n.settingsPush,
                      value: state.pushEnabled,
                      onChanged: state.pushUpdating
                          ? null
                          : (v) => bloc.add(PushToggled(value: v)),
                    ),
                    const _NotificationAccessRow(),
                    _SettingsSwitchRow(
                      icon: Icons.dashboard_customize_outlined,
                      label: i18n.settingsLiveActivity,
                      value: state.liveActivityEnabled,
                      onChanged: (v) => bloc.add(LiveActivityToggled(value: v)),
                    ),
                  ],
                ),
                const SizedBox(height: AppTheme.space24),
                _SettingsSection(
                  title: i18n.settingsSectionPlanner,
                  footer: i18n.settingsPlannerFooter,
                  children: [
                    _SettingsSwitchRow(
                      icon: Icons.accessible_rounded,
                      label: i18n.settingsStepFree,
                      value: state.stepFreeRouting,
                      onChanged: (v) =>
                          bloc.add(StepFreeRoutingToggled(value: v)),
                    ),
                    _SettingsRow(
                      icon: Icons.directions_walk_rounded,
                      label: i18n.settingsWalkPace,
                      value: state.walkPace.labelOf(i18n),
                      chevron: true,
                      onTap: () => _pickWalkPace(context, i18n, state.walkPace),
                    ),
                  ],
                ),
                const SizedBox(height: AppTheme.space24),
                _SettingsSection(
                  title: i18n.settingsSectionFare,
                  // The setting is worth explaining once here rather than
                  // repeating a picker on every fare on every screen: it is
                  // set once and read everywhere.
                  footer: i18n.settingsFareFooter,
                  children: [
                    _SettingsRow(
                      icon: Icons.confirmation_number_outlined,
                      label: i18n.settingsFareType,
                      value: state.fareType.labelOf(i18n),
                      chevron: true,
                      onTap: () => _pickFareType(context, i18n, state.fareType),
                    ),
                  ],
                ),
                const SizedBox(height: AppTheme.space24),
                _SettingsSection(
                  title: i18n.settingsSectionAbout,
                  children: [
                    _SettingsRow(
                      icon: Icons.help_outline_rounded,
                      label: i18n.settingsFaq,
                      comingSoon: true,
                    ),
                    _SettingsSwitchRow(
                      icon: Icons.vibration_rounded,
                      label: i18n.settingsShakeToReport,
                      value: state.shakeToReport,
                      onChanged: (v) =>
                          bloc.add(ShakeToReportToggled(value: v)),
                    ),
                    _SettingsRow(
                      icon: Icons.lock_outline_rounded,
                      label: i18n.settingsPrivacyPolicy,
                      comingSoon: true,
                    ),
                    _SettingsRow(
                      icon: Icons.info_outline_rounded,
                      label: i18n.settingsAppVersion,
                      value: state.appVersion.isEmpty ? '—' : state.appVersion,
                      monoValue: true,
                    ),
                    _UpdateCheckRow(state: state, bloc: bloc),
                    if (FirebaseGate.appEnv != 'prod' &&
                        FirebaseGate.appEnv != 'production')
                      _SettingsRow(
                        icon: Icons.developer_mode_rounded,
                        label: i18n.settingsEnvironment,
                        value: FirebaseGate.appEnv,
                      ),
                  ],
                ),
                const SizedBox(height: AppTheme.space24),
                const _TdxAttribution(),
                _AppIdentityFooter(version: state.appVersion),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LargeTitleHeader extends SliverPersistentHeaderDelegate {
  const _LargeTitleHeader({
    required this.title,
    required this.topPadding,
    required this.reduceMotion,
  });

  final String title;
  final double topPadding;
  final bool reduceMotion;

  static const double _bar = 44;
  static const double _largeBlock = 52;

  static const int _blurSteps = 6;

  @override
  double get minExtent => topPadding + _bar;

  @override
  double get maxExtent => topPadding + _bar + _largeBlock;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    final cs = Theme.of(context).colorScheme;
    final t = (shrinkOffset / _largeBlock).clamp(0.0, 1.0);

    // Each layer fades on its own eased curve so the crossfade reads as one
    // material collapsing, not two opacities racing.
    final chrome = AppMotion.easeOut.transform(t);
    final blurChrome = (chrome * _blurSteps).round() / _blurSteps;
    final compact = AppMotion.easeInOut.transform(
      ((t - 0.35) / 0.65).clamp(0.0, 1.0),
    );
    final large =
        1.0 - AppMotion.easeInOut.transform((t / 0.7).clamp(0.0, 1.0));

    return SizedBox.expand(
      child: Stack(
        children: [
          // Translucent bar: invisible at rest, blurs the content scrolling
          // beneath and drops a hairline once collapse begins.
          if (chrome > 0.001)
            Positioned.fill(
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: 18 * blurChrome,
                    sigmaY: 18 * blurChrome,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.surface.withValues(alpha: 0.72 * chrome),
                      border: Border(
                        bottom: BorderSide(
                          color: cs.outlineVariant.withValues(alpha: chrome),
                          width: 0.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // Back affordance — pinned top-left across the whole collapse.
          Positioned(
            top: topPadding,
            left: 4,
            child: const _BackButton(),
          ),
          // Collapsed centred title.
          Positioned(
            top: topPadding,
            left: 44,
            right: 44,
            height: _bar,
            child: Center(
              child: Opacity(
                opacity: compact,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
              ),
            ),
          ),
          // Resting large title, anchored to the header's bottom edge.
          Positioned(
            left: 20,
            right: 20,
            bottom: 10,
            child: Opacity(
              opacity: large,
              child: Transform.translate(
                offset: Offset(0, reduceMotion ? 0 : t * -6),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.displayLarge,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_LargeTitleHeader old) =>
      old.title != title ||
      old.topPadding != topPadding ||
      old.reduceMotion != reduceMotion;
}

class _BackButton extends StatelessWidget {
  const _BackButton();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Pressable(
      onTap: () => context.pop(),
      semanticLabel: AppI18n.of(context).commonBack,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Icon(
          Icons.arrow_back_ios_new_rounded,
          size: 20,
          color: cs.onSurface,
        ),
      ),
    );
  }
}

class _SettingsSwitchRow extends StatelessWidget {
  const _SettingsSwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.icon,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sw = AppSwitch(value: value, onChanged: onChanged);

    // MergeSemantics prevents duplicate accessibility announcements.
    return MergeSemantics(
      child: Pressable(
        onTap: onChanged != null ? () => onChanged!(!value) : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppTheme.space4),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: cs.onSurfaceVariant),
                  const SizedBox(width: AppTheme.space12),
                ],
                Expanded(child: Text(label, style: AppTextStyles.bodyLarge)),
                const SizedBox(width: AppTheme.space12),
                sw,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationAccessRow extends StatefulWidget {
  const _NotificationAccessRow();

  @override
  State<_NotificationAccessRow> createState() => _NotificationAccessRowState();
}

class _NotificationAccessRowState extends State<_NotificationAccessRow>
    with WidgetsBindingObserver {
  bool _blocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  Future<void> _check() async {
    final enabled = await AlightTrackChannel.notificationsEnabled();
    if (!mounted || enabled == !_blocked) return;
    setState(() => _blocked = !enabled);
  }

  @override
  Widget build(BuildContext context) {
    if (!_blocked) return const SizedBox.shrink();
    final i18n = AppI18n.of(context);
    return _SettingsRow(
      icon: Icons.notifications_off_outlined,
      label: i18n.settingsNotificationsBlocked,
      value: i18n.settingsOpenSystemSettings,
      chevron: true,
      onTap: () => unawaited(AlightTrackChannel.openNotificationSettings()),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.children,
    this.footer,
  });

  final String title;
  final List<Widget> children;

  /// Optional HIG-style footnote rendered under the group. Carries the "why"
  /// for a group of toggles so individual rows stay one scannable line.
  final String? footer;

  // Separators start at the label column (past the 20px icon + 12px gap),
  // the iOS inset-grouped signature; a full-bleed divider reads as a table.
  static const double _dividerIndent = 48;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.space4,
            0,
            AppTheme.space4,
            7,
          ),
          child: Text(
            title,
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            // surfaceContainerLow (card), not surface: an elevated group must
            // never paint the scaffold colour or it vanishes in dark mode.
            color: cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppTheme.radiusCard),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (int i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 0.5,
                    thickness: 0.5,
                    indent: _dividerIndent,
                    color: cs.outlineVariant,
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.space16,
                  ),
                  child: children[i],
                ),
              ],
            ],
          ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.space6,
              7,
              AppTheme.space6,
              0,
            ),
            child: Text(
              footer!,
              style: AppTextStyles.bodySmall.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

class _TdxAttribution extends StatelessWidget {
  const _TdxAttribution();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = AppI18n.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space6,
        AppTheme.space12,
        AppTheme.space6,
        0,
      ),
      child: Text(
        i18n.settingsSource,
        style: AppTextStyles.bodySmall.copyWith(
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _UpdateCheckRow extends StatelessWidget {
  const _UpdateCheckRow({required this.state, required this.bloc});

  final SettingsState state;
  final SettingsBloc bloc;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = AppI18n.of(context);
    final found = state.updateCheck == UpdateCheck.available;
    // A found release is only actionable with a store link that passes the
    // allowlist; without one the row states the version and stops being
    // tappable, rather than offering a chevron that goes nowhere (F45).
    final url = found ? storeUrl() : null;
    // The label follows what a tap actually does, not merely what was found:
    // 「前往更新」 on a row that cannot navigate anywhere would be the same
    // dead affordance one level up from the chevron.
    final label = switch ((found, url)) {
      (true, != null) => i18n.settingsUpdateGo,
      (true, _) => i18n.settingsUpdateAvailable,
      _ => i18n.settingsUpdateCheck,
    };

    final value = switch (state.updateCheck) {
      UpdateCheck.idle => null,
      UpdateCheck.checking => i18n.settingsUpdateChecking,
      UpdateCheck.upToDate => i18n.settingsUpdateUpToDate,
      UpdateCheck.failed => i18n.settingsUpdateFailed,
      UpdateCheck.available => state.latestVersion,
    };

    return _SettingsRow(
      icon: Icons.system_update_rounded,
      label: label,
      value: value,
      // Versions are figures, so they get mono like every other one; the
      // status strings are prose and stay in the body face.
      monoValue: found,
      // Ink, not a status colour: the design system reserves hue for transit
      // line identity, so a found release is emphasised by contrast alone.
      valueColor: found ? cs.onSurface : null,
      chevron: url != null,
      onTap: switch (state.updateCheck) {
        UpdateCheck.checking => null,
        UpdateCheck.available =>
          url == null
              ? null
              : () {
                  unawaited(HapticService.instance.lightTap());
                  unawaited(
                    launchUrl(url, mode: LaunchMode.externalApplication),
                  );
                },
        _ => () {
          unawaited(HapticService.instance.lightTap());
          bloc.add(const UpdateCheckRequested());
        },
      },
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.label,
    this.value,
    this.valueColor,
    this.chevron = false,
    this.monoValue = false,
    this.onTap,
    this.comingSoon = false,
  });
  final IconData icon;
  final String label;
  final String? value;
  final Color? valueColor;
  final bool chevron;

  /// Renders the trailing value in IBM Plex Mono (tabular): versions and sync
  /// timestamps, where digits should not shift width between states.
  final bool monoValue;
  final VoidCallback? onTap;

  final bool comingSoon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = AppI18n.of(context);
    // Trailing detail is secondary, at label size — the label leads, the
    // value supports (HIG). Mono values keep tabular figures.
    final baseValue = monoValue ? AppTextStyles.memo : AppTextStyles.bodyLarge;
    final valueStyle = baseValue.copyWith(
      color: valueColor ?? cs.onSurfaceVariant,
    );

    // Min-height, not fixed: a wrapped label under a large text scale grows
    // the row instead of being clipped (F53).
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Pressable(
        onTap: comingSoon ? null : onTap,
        semanticLabel: comingSoon
            ? i18n.commonComingSoonSemantics(label)
            : label,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppTheme.space10),
          child: Row(
            children: [
              Icon(icon, size: 20, color: cs.onSurfaceVariant),
              const SizedBox(width: AppTheme.space12),
              Expanded(child: Text(label, style: AppTextStyles.bodyLarge)),
              if (comingSoon)
                Text(
                  i18n.commonComingSoon,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                )
              else ...[
                if (value != null)
                  Text(value!, textAlign: TextAlign.right, style: valueStyle),
                if (chevron) ...[
                  const SizedBox(width: AppTheme.space4),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: cs.outline,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Closes the list with the app's own name and version, so the About group
/// isn't the only place the app identifies itself.
class _AppIdentityFooter extends StatelessWidget {
  const _AppIdentityFooter({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: AppTheme.space8),
      child: Column(
        children: [
          Text(
            AppI18n.of(context).appName,
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (version.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              version,
              style: AppTextStyles.memo.copyWith(color: cs.outline),
            ),
          ],
        ],
      ),
    );
  }
}

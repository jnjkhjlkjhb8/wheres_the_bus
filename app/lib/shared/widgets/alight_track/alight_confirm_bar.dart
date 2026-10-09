import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/haptics/haptic_service.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

/// A binding fact, e.g. `1021 車` or `KKA-1234`. Exposed because each network
/// assembles its own [AlightConfirmBar.binding] from these.
class AlightBindingChip extends StatelessWidget {
  const AlightBindingChip({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space8,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radiusChip),
      ),
      child: Text(label, style: AppTextStyles.memo.copyWith(fontSize: 12)),
    );
  }
}

class AlightConfirmBar extends StatelessWidget {
  const AlightConfirmBar({
    required this.targetName,
    required this.lead,
    required this.onLeadChanged,
    required this.onStart,
    required this.onCancel,
    this.onRepick,
    this.binding,
    this.fromSearch = false,
    this.leadMin = 0,
    this.leadMax = 3,
    this.canStart = true,
    this.busy = false,
    this.errorText,
    super.key,
  });

  /// The chosen 下車站, named back to the rider.
  final String targetName;

  /// 提前站數.
  final int lead;
  final ValueChanged<int> onLeadChanged;

  final VoidCallback onStart;

  /// Leaves the whole flow with nothing started.
  final VoidCallback onCancel;

  /// Returns to pick-mode for a different stop. Null where the stop cannot be
  /// changed from here.
  final VoidCallback? onRepick;

  /// The 綁定 row — a chip, a car-number field, a list of candidate plates.
  final Widget? binding;

  /// Whether [targetName] came from the rider's own O/D search rather than a
  /// tap here. Said out loud, because a value that filled itself in owes an
  /// explanation of where it came from.
  final bool fromSearch;

  final int leadMin;
  final int leadMax;

  /// Extra gate on the CTA for a binding the caller has not completed — a car
  /// number still to be typed, say.
  final bool canStart;

  final bool busy;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _Dock(
      children: [
        _PickedLine(
          targetName: targetName,
          fromSearch: fromSearch,
          onRepick: onRepick,
          onCancel: onCancel,
        ),
        if (binding != null) ...[
          const SizedBox(height: AppTheme.space12),
          binding!,
        ],
        const SizedBox(height: AppTheme.space12),
        _LeadStepper(
          value: lead,
          min: leadMin,
          max: leadMax,
          targetName: targetName,
          onChanged: onLeadChanged,
        ),
        if (errorText != null) ...[
          const SizedBox(height: AppTheme.space10),
          Text(
            errorText!,
            style: AppTextStyles.bodySmall.copyWith(color: cs.error),
          ),
        ],
        const SizedBox(height: AppTheme.space12),
        _StartButton(enabled: canStart && !busy, busy: busy, onTap: onStart),
      ],
    );
  }
}

class AlightManageBar extends StatelessWidget {
  const AlightManageBar({
    required this.targetName,
    required this.lead,
    required this.onClose,
    required this.onCancel,
    this.bindingLabel,
    super.key,
  });

  final String targetName;
  final int lead;
  final VoidCallback onClose;
  final VoidCallback onCancel;

  /// Plate or car id — which vehicle the session follows. Null where the
  /// screen itself already names it.
  final String? bindingLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = AppI18n.of(context);
    return _Dock(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.space12,
            vertical: AppTheme.space10,
          ),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppTheme.radiusButton),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  i18n.alightArmedSummary(targetName, lead),
                  style: AppTextStyles.bodyRegular,
                ),
              ),
              if (bindingLabel != null) ...[
                const SizedBox(width: AppTheme.space8),
                AlightBindingChip(label: bindingLabel!),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppTheme.space12),
        Row(
          children: [
            Expanded(
              child: _GhostButton(
                label: i18n.commonClose,
                quiet: true,
                onTap: onClose,
              ),
            ),
            const SizedBox(width: AppTheme.space10),
            Expanded(
              child: _GhostButton(
                label: i18n.alightCancelReminder,
                onTap: () {
                  unawaited(HapticService.instance.mediumTap());
                  onCancel();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Shared chrome for both bars: a bottom-anchored card that clears the home
/// indicator and reads as one layer above the content it covers.
class _Dock extends StatelessWidget {
  const _Dock({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      child: SafeArea(
        top: false,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(
            AppTheme.space16,
            AppTheme.space12,
            AppTheme.space16,
            AppTheme.space16,
          ),
          decoration: BoxDecoration(
            color: cs.surface,
            border: Border(top: BorderSide(color: cs.outlineVariant)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// Names the chosen stop and offers the two edits: a different stop, or none
/// at all.
class _PickedLine extends StatelessWidget {
  const _PickedLine({
    required this.targetName,
    required this.fromSearch,
    required this.onRepick,
    required this.onCancel,
  });

  final String targetName;
  final bool fromSearch;
  final VoidCallback? onRepick;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = AppI18n.of(context);
    final label = fromSearch
        ? '${i18n.alightPickedStop(targetName)} ${i18n.alightFromSearch}'
        : i18n.alightPickedStop(targetName);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space12,
        vertical: AppTheme.space6,
      ),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radiusButton),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: AppTextStyles.bodyRegular,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onRepick != null)
            Pressable(
              onTap: onRepick,
              semanticLabel: i18n.alightRepick,
              minTapSize: 44,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.space8,
                  vertical: AppTheme.space6,
                ),
                child: Text(
                  i18n.alightRepick,
                  style: AppTextStyles.bodySmall.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ),
          Pressable(
            onTap: onCancel,
            semanticLabel: i18n.commonClose,
            minTapSize: 44,
            child: Padding(
              padding: const EdgeInsets.all(AppTheme.space4),
              child: Icon(
                Icons.close_rounded,
                size: 18,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LeadStepper extends StatelessWidget {
  const _LeadStepper({
    required this.value,
    required this.min,
    required this.max,
    required this.targetName,
    required this.onChanged,
  });

  final int value;
  final int min;
  final int max;
  final String targetName;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final i18n = AppI18n.of(context);
    return Row(
      children: [
        _StepButton(
          icon: Icons.remove_rounded,
          enabled: value > min,
          onTap: () => onChanged(value - 1),
          semanticLabel: i18n.commonDecrease,
        ),
        const SizedBox(width: AppTheme.space12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (value == 0)
                Text(
                  i18n.alightNoLead(targetName),
                  style: AppTextStyles.bodyRegular,
                )
              else
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: targetName,
                        style: AppTextStyles.bodyRegular.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const TextSpan(text: ' '),
                      TextSpan(
                        text: i18n.mrtAlightLeadLabel,
                        style: AppTextStyles.bodyRegular,
                      ),
                      const TextSpan(text: ' '),
                      TextSpan(
                        text: i18n.stopsCount(value),
                        style: AppTextStyles.memo.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              Text(
                value == 0 ? i18n.alightVibrateBoth : i18n.alightVibrateLead,
                style: AppTextStyles.bodyVerySmall.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppTheme.space12),
        _StepButton(
          icon: Icons.add_rounded,
          enabled: value < max,
          onTap: () => onChanged(value + 1),
          semanticLabel: i18n.commonIncrease,
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
    required this.semanticLabel,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Pressable(
      enabled: enabled,
      onTap: onTap,
      semanticLabel: semanticLabel,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(AppTheme.radiusButton),
        ),
        child: Icon(
          icon,
          size: 20,
          color: enabled ? cs.onSurface : cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.label,
    required this.onTap,
    this.quiet = false,
  });

  final String label;
  final VoidCallback onTap;

  /// The low-emphasis half of the pair: no border, secondary ink. Cancelling a
  /// reminder is reversible in a few taps, so neither half borrows the
  /// destructive red the system reserves for irreversible actions.
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(
            color: quiet ? Colors.transparent : cs.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(AppTheme.radiusButton),
        ),
        child: Text(
          label,
          style: AppTextStyles.bodyRegular.copyWith(
            fontWeight: FontWeight.w600,
            color: quiet ? cs.onSurfaceVariant : cs.onSurface,
          ),
        ),
      ),
    );
  }
}

class _StartButton extends StatelessWidget {
  const _StartButton({
    required this.enabled,
    required this.busy,
    required this.onTap,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = AppI18n.of(context).mrtAlightStart;
    return Pressable(
      enabled: enabled,
      onTap: () {
        unawaited(HapticService.instance.mediumTap());
        onTap();
      },
      semanticLabel: label,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? cs.onSurface : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppTheme.radiusButton),
        ),
        child: busy
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: cs.surface,
                ),
              )
            : Text(
                label,
                style: AppTextStyles.bodyLarge.copyWith(
                  fontWeight: FontWeight.w700,
                  color: enabled ? cs.surface : cs.onSurfaceVariant,
                ),
              ),
      ),
    );
  }
}

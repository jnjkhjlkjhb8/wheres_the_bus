part of '../view/metro_screen.dart';

/// Floating time/fare toggle mirroring the system pill's card styling. Drives
/// [MetroMapMode], which controls the labels shown on every station across
/// the map.
class _MapModeChip extends StatelessWidget {
  const _MapModeChip({
    required this.mode,
    required this.onChanged,
    super.key,
  });

  final MetroMapMode mode;
  final ValueChanged<MetroMapMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final i18n = AppI18n.of(context);
    return AppSlidingSegment<MetroMapMode>(
      style: AppSegmentStyle.floating,
      // Hugs its labels rather than stretching: it floats beside the system
      // pill over the map, where a full-width control would cover the network.
      fill: false,
      // Built per call rather than held in a static: the labels follow the
      // rider's language, which a `static const` would freeze at first load.
      options: {
        MetroMapMode.time: i18n.metroMapModeTime,
        MetroMapMode.fare: i18n.metroMapModeFare,
      },
      value: mode,
      onChanged: onChanged,
    );
  }
}

class _SystemPill extends StatefulWidget {
  const _SystemPill();

  @override
  State<_SystemPill> createState() => _SystemPillState();
}

class _SystemPillState extends State<_SystemPill> {
  /// Resolved per build rather than held in a static: the labels follow the
  /// rider's language, which a `static const` would freeze at first load.
  List<String> _others(AppI18n i18n) => [
    i18n.metroSystemKrtc,
    i18n.metroSystemTymc,
    i18n.metroSystemKlrt,
  ];
  bool _isPickerOpen = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: AppI18n.of(context).metroSwitchSystem,
      button: true,
      child: Pressable(
        onTap: () => _showPicker(context),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.space14),
          // Same skin as the back button and the time/fare segment beside it:
          // hand-rolling it here drifted (shadow in dark mode, no hairline).
          decoration: AppTheme.floatingControl(
            cs,
            borderRadius: const BorderRadius.all(
              Radius.circular(AppTheme.radiusStadium),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: AppTheme.space4,
            children: [
              Text(
                AppI18n.of(context).metroSystemTrtc,
                style: AppTextStyles.bodyLarge.copyWith(
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              AnimatedRotation(
                turns: _isPickerOpen ? 0.5 : 0.0,
                duration: AppMotion.short,
                child: Icon(
                  Icons.expand_more_rounded,
                  size: 18,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPicker(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final box = context.findRenderObject()! as RenderBox;
    final pos = box.localToGlobal(Offset.zero);

    setState(() => _isPickerOpen = true);

    unawaited(
      showMenu<String>(
        context: context,
        color: cs.surfaceContainerLow,
        constraints: BoxConstraints(
          minWidth: box.size.width,
          maxWidth: box.size.width,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        position: RelativeRect.fromLTRB(
          pos.dx,
          pos.dy + box.size.height + 4,
          pos.dx + box.size.width,
          0,
        ),
        items: _others(AppI18n.of(context))
            .map(
              (s) => PopupMenuItem(
                value: s,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.space12,
                ),
                child: Text(
                  s,
                  style: AppTextStyles.bodyLarge.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
            .toList(),
      ).then((value) {
        if (mounted) {
          setState(() => _isPickerOpen = false);
        }
        if (value != null && context.mounted) {
          AppSnackbar.show(context, AppI18n.of(context).comingSoonValue(value));
        }
      }),
    );
  }
}

part of '../view/go_screen.dart';

const _kPlannerHorizon = Duration(days: 15);

class _GoMessage extends StatelessWidget {
  const _GoMessage({
    required this.icon,
    required this.title,
    required this.hint,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String hint;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.space24,
          AppTheme.space48,
          AppTheme.space24,
          AppTheme.space24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppTheme.inkTertiary(cs.brightness)),
            const SizedBox(height: AppTheme.space16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyLarge.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: AppTheme.space6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySmall.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: AppTheme.space20),
              Pressable(
                onTap: onAction,
                semanticLabel: actionLabel,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.space20,
                    vertical: AppTheme.space12,
                  ),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(AppTheme.radiusButton),
                  ),
                  child: Text(
                    actionLabel!,
                    style: AppTextStyles.bodyRegular.copyWith(
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PlannerEntry extends StatelessWidget {
  const _PlannerEntry({
    required this.origin,
    required this.originStatus,
    required this.savedRoutes,
    required this.savedRoutesReady,
    required this.savedRoutesLoadError,
    required this.onEditOrigin,
    required this.onSwap,
    required this.onPickDestination,
    required this.onOpenSaved,
    required this.onToggleSave,
    required this.onBack,
    required this.onEnableLocation,
    required this.onRetrySavedRoutes,
    super.key,
  });

  final PlannedPlace? origin;
  final OriginStatus originStatus;
  final List<PlanRoute> savedRoutes;
  final bool savedRoutesReady;
  final bool savedRoutesLoadError;
  final VoidCallback onEditOrigin;
  final VoidCallback onSwap;
  final ValueChanged<PlannedPlace> onPickDestination;
  final void Function(PlanRoute) onOpenSaved;
  final void Function(PlanRoute) onToggleSave;
  final VoidCallback onBack;
  final VoidCallback onEnableLocation;
  final VoidCallback onRetrySavedRoutes;

  // 路線箱: the saved-route cards. Kept out of PlaceSearchView (which only knows
  // places) by passing it in as the list header.
  Widget? _savedRoutesHeader(BuildContext context) {
    if (!savedRoutesReady && savedRoutesLoadError) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.space20,
          AppTheme.space16,
          AppTheme.space20,
          AppTheme.space12,
        ),
        child: Row(
          children: [
            const Icon(Icons.cloud_off_outlined, size: 20),
            const SizedBox(width: AppTheme.space8),
            Expanded(child: Text('路線箱暫時無法讀取')),
            TextButton(onPressed: onRetrySavedRoutes, child: const Text('重試')),
          ],
        ),
      );
    }
    if (!savedRoutesReady) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(
          AppTheme.space20,
          AppTheme.space16,
          AppTheme.space20,
          AppTheme.space12,
        ),
        child: SizedBox(
          height: 24,
          child: Align(
            alignment: Alignment.centerLeft,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (savedRoutes.isEmpty) return null;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.space20,
            AppTheme.space16,
            AppTheme.space20,
            AppTheme.space6,
          ),
          child: Text(
            AppI18n.of(context).goRouteBox,
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.space16,
            0,
            AppTheme.space16,
            AppTheme.space4,
          ),
          child: Column(
            children: [
              for (final route in savedRoutes)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.space10),
                  child: RouteOptionCard(
                    route: route,
                    highlighted: false,
                    isSaved: true,
                    onTap: () => onOpenSaved(route),
                    onToggleSave: () => onToggleSave(route),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ColoredBox(
      color: cs.surface,
      child: SafeArea(
        bottom: false,
        child: PlaceSearchView(
          fieldLabel: AppI18n.of(context).goSearchDestination,
          // Picking here sets the *destination*, and "current location" is not
          // somewhere anyone travels to.
          allowCurrentLocation: false,
          emptyHint: AppI18n.of(context).goSearchDestinationHint,
          header: _savedRoutesHeader(context),
          onPicked: onPickDestination,
          headerBuilder: (context, input) => Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.space4,
              AppTheme.space4,
              AppTheme.space16,
              AppTheme.space4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Pressable(
                      onTap: onBack,
                      semanticLabel: AppI18n.of(context).commonBack,
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(
                          Icons.arrow_back_rounded,
                          size: 22,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    Text(
                      AppI18n.of(context).goPlanRoute,
                      style: AppTextStyles.bodyLarge.copyWith(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppTheme.space12,
                    AppTheme.space4,
                    0,
                    AppTheme.space4,
                  ),
                  child: _ODFields(
                    origin: origin,
                    originStatus: originStatus,
                    onEditOrigin: onEditOrigin,
                    onSwap: onSwap,
                    onEnableLocation: onEnableLocation,
                    destination: Align(
                      alignment: Alignment.centerLeft,
                      child: input,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Results-header chip that reads out the current departure/arrival stance and
/// opens the time selector.
class _TimeChip extends StatelessWidget {
  const _TimeChip({required this.mode, required this.at, required this.onTap});

  final _TimeMode mode;
  final DateTime at;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${two(at.month)}/${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
    final suffix = switch (mode) {
      _TimeMode.leaveNow => null,
      _TimeMode.departAt => AppI18n.of(context).goDepartSuffix,
      _TimeMode.arriveBy => AppI18n.of(context).goArriveSuffix,
    };
    final sansStyle = AppTextStyles.bodySmall.copyWith(
      color: cs.onSurface,
      fontWeight: FontWeight.w600,
    );
    return Pressable(
      onTap: onTap,
      semanticLabel: AppI18n.of(context).goChooseDepartTime,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.space12,
          vertical: AppTheme.space8,
        ),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppTheme.radiusButton),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule_rounded, size: 16, color: cs.onSurface),
            const SizedBox(width: AppTheme.space6),
            if (suffix == null)
              Text(AppI18n.of(context).goLeaveNow, style: sansStyle)
            else ...[
              Text(
                stamp,
                style: AppTextStyles.timeValue(
                  size: sansStyle.fontSize,
                  weight: sansStyle.fontWeight,
                  color: sansStyle.color,
                ),
              ),
              Text(suffix, style: sansStyle),
            ],
          ],
        ),
      ),
    );
  }
}

// Built per call rather than held in a const map: the names follow the
// rider's language.
Map<int, String> _weekdayLabels(AppI18n i18n) => {
  DateTime.monday: i18n.weekdayMon,
  DateTime.tuesday: i18n.weekdayTue,
  DateTime.wednesday: i18n.weekdayWed,
  DateTime.thursday: i18n.weekdayThu,
  DateTime.friday: i18n.weekdayFri,
  DateTime.saturday: i18n.weekdaySat,
  DateTime.sunday: i18n.weekdaySun,
};

/// Departure/arrival time selector, mirroring the rail query's
/// date + time + stance idiom. Returns the chosen `(mode, at)` on 套用, or null
/// on dismiss.
Future<({_TimeMode mode, DateTime at})?> _showTimeModeSheet(
  BuildContext context, {
  required _TimeMode mode,
  required DateTime at,
}) {
  return showModalBottomSheet<({_TimeMode mode, DateTime at})>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _TimeModeSheet(mode: mode, at: at),
  );
}

class _TimeModeSheet extends StatefulWidget {
  const _TimeModeSheet({required this.mode, required this.at});

  final _TimeMode mode;
  final DateTime at;

  @override
  State<_TimeModeSheet> createState() => _TimeModeSheetState();
}

class _TimeModeSheetState extends State<_TimeModeSheet> {
  late _TimeMode _mode = widget.mode;
  late DateTime _at = widget.at;

  Future<void> _pickDate() async {
    final cs = Theme.of(context).colorScheme;
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusBottomSheet),
        ),
      ),
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.space16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetDragHandle(),
              const SizedBox(height: AppTheme.space8),
              AppDatePicker(
                selectedDay: _at,
                firstDay: DateTime.now(),
                lastDay: DateTime.now().add(_kPlannerHorizon),
                onDaySelected: (date) => Navigator.pop(context, date),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) {
      // Preserve the chosen time-of-day when only the date changes.
      setState(() {
        _at = DateTime(
          picked.year,
          picked.month,
          picked.day,
          _at.hour,
          _at.minute,
        );
      });
    }
  }

  Future<void> _pickTime() async {
    final picked = await AppTimePicker.show(
      context,
      TimeOfDay(hour: _at.hour, minute: _at.minute),
    );
    if (picked != null && mounted) {
      setState(() {
        _at = DateTime(
          _at.year,
          _at.month,
          _at.day,
          picked.hour,
          picked.minute,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    String two(int v) => v.toString().padLeft(2, '0');
    final timed = _mode != _TimeMode.leaveNow;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusBottomSheet),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SheetDragHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.space20,
                AppTheme.space4,
                AppTheme.space20,
                AppTheme.space12,
              ),
              child: Text(
                AppI18n.of(context).goDepartAt,
                style: AppTextStyles.heading2.copyWith(color: cs.onSurface),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppTheme.space20),
              child: AppSlidingSegment<_TimeMode>(
                options: {
                  _TimeMode.leaveNow: AppI18n.of(context).goLeaveNow,
                  _TimeMode.departAt: AppI18n.of(context).goDepartAt,
                  _TimeMode.arriveBy: AppI18n.of(context).goArriveBy,
                },
                value: _mode,
                onChanged: (v) => setState(() => _mode = v),
              ),
            ),
            if (timed) ...[
              const SizedBox(height: AppTheme.space8),
              _TimeRow(
                icon: Icons.event_rounded,
                label: AppI18n.of(context).commonDate,
                value:
                    '${two(_at.month)}/${two(_at.day)}'
                    '（${_weekdayLabels(AppI18n.of(context))[_at.weekday]}）',
                onTap: _pickDate,
              ),
              _TimeRow(
                icon: Icons.schedule_rounded,
                label: AppI18n.of(context).commonTime,
                value: '${two(_at.hour)}:${two(_at.minute)}',
                onTap: _pickTime,
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.space20,
                AppTheme.space16,
                AppTheme.space20,
                AppTheme.space12,
              ),
              child: SizedBox(
                width: double.infinity,
                child: AppButton(
                  label: AppI18n.of(context).commonApply,
                  onPressed: () =>
                      Navigator.of(context).pop((mode: _mode, at: _at)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeRow extends StatelessWidget {
  const _TimeRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Pressable(
      onTap: onTap,
      semanticLabel: '$label $value',
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.space20,
          vertical: AppTheme.space14,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: cs.onSurfaceVariant),
            const SizedBox(width: AppTheme.space12),
            Text(
              label,
              style: AppTextStyles.bodyLarge.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.space14,
                vertical: AppTheme.space8,
              ),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppTheme.radiusButton),
              ),
              child: Text(
                value,
                style: AppTextStyles.memo.copyWith(color: cs.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

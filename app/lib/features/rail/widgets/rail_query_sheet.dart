import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_card.dart';
import 'package:wheres_the_bus/shared/widgets/app_date_picker.dart';
import 'package:wheres_the_bus/shared/widgets/app_sliding_segment.dart';
import 'package:wheres_the_bus/shared/widgets/app_time_picker.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';
import 'package:wheres_the_bus/shared/widgets/thsr_station_picker.dart';
import 'package:wheres_the_bus/shared/widgets/tra_station_picker.dart';

const List<FontFeature> _tnum = AppTextStyles.tabularFigures;

final TextStyle _fieldValueStyle = AppTextStyles.bodyLarge.copyWith(
  fontWeight: FontWeight.w700,
  fontSize: 18,
  fontFeatures: _tnum,
);

/// Mode-pane cross-fade duration; ~200 ms sits in the app's short-motion band.
const Duration _kPaneSwitch = AppMotion.short;

// Built per call rather than held in a const map: the names follow the
// rider's language.
Map<int, String> _weekdayMap(AppI18n i18n) => {
  DateTime.monday: i18n.weekdayMon,
  DateTime.tuesday: i18n.weekdayTue,
  DateTime.wednesday: i18n.weekdayWed,
  DateTime.thursday: i18n.weekdayThu,
  DateTime.friday: i18n.weekdayFri,
  DateTime.saturday: i18n.weekdaySat,
  DateTime.sunday: i18n.weekdaySun,
};

String _formatDateDisplay(AppI18n i18n, DateTime date) {
  return '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} (${_weekdayMap(i18n)[date.weekday]})';
}

String _formatTime(TimeOfDay time) {
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// Shown in place of an unpicked station. The form starts empty rather than
/// seeded with a station pair: a pre-filled O/D reads as the user's own query
/// and invites a 查詢 tap that runs someone else's route.
String _stationPlaceholder(AppI18n i18n) => i18n.railChooseStation;

/// Which form the query sheet is showing.
enum RailQueryMode { od, train }

/// Optional seed for the sheet: pre-fills the origin (and, when known, dest and
/// date) so opening from a station detail — or re-opening after a home-sheet
/// hand-off — shows the query that is actually in effect.
class RailQueryPreset {
  const RailQueryPreset({
    required this.system,
    this.originName,
    this.originId,
    this.destName,
    this.destId,
    this.date,
    this.isDeparture = true,
  });

  final RailSystem system;
  final String? originName;
  final String? originId;
  final String? destName;
  final String? destId;
  final DateTime? date;
  final bool isDeparture;
}

/// A completed query, handed back to the host via `onSubmit`.
sealed class RailQuerySubmission {
  const RailQuerySubmission();

  RailSystem get system;
}

final class RailOdQuerySubmission extends RailQuerySubmission {
  const RailOdQuerySubmission({
    required this.system,
    required this.originName,
    required this.destName,
    required this.date,
    required this.isDeparture,
    this.originId,
    this.destId,
  });

  @override
  final RailSystem system;
  final String originName;
  final String? originId;
  final String destName;
  final String? destId;
  // [date] carries the selected time-of-day too; it bounds the results (the
  // backend request itself stays date-only).
  final DateTime date;
  // true: [date]'s time is a "depart at/after"; false: an "arrive at/before".
  final bool isDeparture;
}

final class RailTrainQuerySubmission extends RailQuerySubmission {
  const RailTrainQuerySubmission({
    required this.system,
    required this.trainNo,
    required this.date,
  });

  @override
  final RailSystem system;
  final String trainNo;
  final DateTime date;
}

class RailQuerySheetContent extends StatefulWidget {
  const RailQuerySheetContent({
    required this.onSubmit,
    this.preset,
    this.onSystemChanged,
    this.onBack,
    super.key,
  });

  final RailQueryPreset? preset;
  final ValueChanged<RailQuerySubmission> onSubmit;
  final ValueChanged<RailSystem>? onSystemChanged;

  final VoidCallback? onBack;

  @override
  State<RailQuerySheetContent> createState() => _RailQuerySheetContentState();
}

class _RailQuerySheetContentState extends State<RailQuerySheetContent> {
  RailQueryMode _mode = RailQueryMode.od;
  late RailSystem _system;
  late String _originName;
  String _originId = '';
  late String _destName;
  String _destId = '';
  late DateTime _selectedDate;
  bool _isDepartureTime = true;
  TimeOfDay _selectedTime = TimeOfDay.now();

  final _trainController = TextEditingController();
  List<Map<String, dynamic>> _recentQueries = const [];

  /// True once an O/D query has been submitted this session — swapping O/D then
  /// re-runs the query immediately, matching the old sheet's behaviour.
  bool _hasSubmittedOd = false;

  @override
  void initState() {
    super.initState();
    final preset = widget.preset;
    _system = preset?.system ?? RailSystem.tra;
    _originName = preset?.originName ?? '';
    _originId = preset?.originId ?? '';
    _destName = preset?.destName ?? '';
    // A hand-off can name the same station twice (a station detail whose stop
    // is also the preset destination); clear the dest rather than submit a
    // zero-length trip.
    if (_originName.isNotEmpty && _originName == _destName) _destName = '';
    _destId = preset?.destId ?? '';
    _selectedDate = preset?.date ?? DateTime.now();
    // Seed the time picker from the preset so a re-opened sheet shows the time
    // that produced the current results (the date carries it).
    if (preset?.date != null) {
      _selectedTime = TimeOfDay.fromDateTime(preset!.date!);
    }
    _isDepartureTime = preset?.isDeparture ?? true;
    if (_originName.isEmpty && _destName.isEmpty) {
      _seedOdFromLastQuery(_system);
    }
    _recentQueries = HiveStore.recentTrainQueries;
    _trainController.addListener(_onTrainTextChanged);
  }

  @override
  void dispose() {
    _trainController
      ..removeListener(_onTrainTextChanged)
      ..dispose();
    super.dispose();
  }

  /// Fills the O/D fields from the rider's last query on [system], or clears
  /// them when there is none. Caller owns `setState`.
  void _seedOdFromLastQuery(RailSystem system) {
    final last = HiveStore.lastOdQuery(system.name);
    _originName = last?['originName'] as String? ?? '';
    _originId = last?['originId'] as String? ?? '';
    _destName = last?['destName'] as String? ?? '';
    _destId = last?['destId'] as String? ?? '';
  }

  void _onTrainTextChanged() => setState(() {});

  void _setMode(RailQueryMode mode) {
    if (mode == _mode) return;
    setState(() => _mode = mode);
  }

  void _switchSystem(RailSystem system) {
    if (system == _system) return;
    setState(() {
      _system = system;
      _seedOdFromLastQuery(system);
      _hasSubmittedOd = false;
    });
    widget.onSystemChanged?.call(system);
  }

  void _swap() {
    setState(() {
      final tmpName = _originName;
      final tmpId = _originId;
      _originName = _destName;
      _originId = _destId;
      _destName = tmpName;
      _destId = tmpId;
    });
    if (_hasSubmittedOd) _submitOd();
  }

  Future<String?> _showStationPicker() => _system == RailSystem.thsr
      ? showTHSRStationPicker(context)
      : showTRAStationPicker(context);

  Future<void> _pickOrigin() async {
    final name = await _showStationPicker();
    if (name != null && mounted) {
      setState(() {
        _originName = name;
        _originId = '';
      });
    }
  }

  Future<void> _pickDest() async {
    final name = await _showStationPicker();
    if (name != null && mounted) {
      setState(() {
        _destName = name;
        _destId = '';
      });
    }
  }

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
      builder: (context) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.space16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SheetDragHandle(),
                const SizedBox(height: AppTheme.space8),
                AppDatePicker(
                  selectedDay: _selectedDate,
                  onDaySelected: (date) => Navigator.pop(context, date),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null && mounted) {
      setState(() => _selectedDate = picked);
    }
  }

  void _submitOd() {
    _hasSubmittedOd = true;
    widget.onSubmit(
      RailOdQuerySubmission(
        system: _system,
        originName: _originName,
        originId: _originId.isEmpty ? null : _originId,
        destName: _destName,
        destId: _destId.isEmpty ? null : _destId,
        // Fold the selected time into the date so it rides every downstream
        // path (results filter, home hand-off) without extra plumbing.
        date: DateTime(
          _selectedDate.year,
          _selectedDate.month,
          _selectedDate.day,
          _selectedTime.hour,
          _selectedTime.minute,
        ),
        isDeparture: _isDepartureTime,
      ),
    );
  }

  void _submitTrain() {
    final trainNo = _trainController.text.trim();
    if (trainNo.isEmpty) return;
    widget.onSubmit(
      RailTrainQuerySubmission(
        system: _system,
        trainNo: trainNo,
        date: _selectedDate,
      ),
    );
    unawaited(
      HiveStore.addRecentTrainQuery(
        _system == RailSystem.thsr ? 'thsr' : 'tra',
        trainNo,
      ),
    );
    setState(() => _recentQueries = HiveStore.recentTrainQueries);
  }

  void _fillFromRecent(String system, String trainNo) {
    final chipSystem = system == 'thsr' ? RailSystem.thsr : RailSystem.tra;
    final systemChanged = chipSystem != _system;
    setState(() {
      _system = chipSystem;
      _trainController.text = trainNo;
    });
    // Only notify on a real switch: the host clears loaded results on system
    // change, which would be gratuitous when the chip matches the current one.
    if (systemChanged) widget.onSystemChanged?.call(chipSystem);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    final pane = _mode == RailQueryMode.od
        ? _buildOdPane(cs)
        : _buildTrainPane(cs);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space16,
        0,
        AppTheme.space16,
        AppTheme.space24,
      ),
      physics: const NeverScrollableScrollPhysics(),
      // Without this the list expands to the full viewport, so the sheet reads
      // the page as full-height: it opens at the top instead of the requested
      // detent and its drag range collapses to a single offset.
      shrinkWrap: true,
      children: [
        const SheetDragHandle(),
        Row(
          children: [
            if (widget.onBack != null)
              Pressable(
                onTap: () {
                  widget.onBack!();
                },
                semanticLabel: AppI18n.of(context).commonBack,
                minTapSize: 44,
                child: Padding(
                  padding: const EdgeInsets.only(right: AppTheme.space8),
                  child: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    size: 18,
                    color: cs.onSurface,
                  ),
                ),
              ),
            Text(
              AppI18n.of(context).railTimetableTitle,
              style: AppTextStyles.bodyLarge.copyWith(
                fontWeight: FontWeight.w700,
                fontSize: 22,
                color: cs.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppTheme.space16),
        AppSlidingSegment<RailQueryMode>(
          options: {
            RailQueryMode.od: AppI18n.of(context).railModeOd,
            RailQueryMode.train: AppI18n.of(context).railModeTrain,
          },
          value: _mode,
          onChanged: _setMode,
        ),
        const SizedBox(height: AppTheme.space12),
        AppSlidingSegment<RailSystem>(
          options: {
            RailSystem.tra: AppI18n.of(context).modeTra,
            RailSystem.thsr: AppI18n.of(context).modeThsr,
          },
          value: _system,
          onChanged: _switchSystem,
        ),
        const SizedBox(height: AppTheme.space16),
        if (reduceMotion)
          KeyedSubtree(key: ValueKey(_mode), child: pane)
        else
          AnimatedSize(
            duration: _kPaneSwitch,
            curve: AppMotion.easeOut,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: _kPaneSwitch,
              switchInCurve: AppMotion.easeOut,
              switchOutCurve: AppMotion.easeOut,
              child: KeyedSubtree(key: ValueKey(_mode), child: pane),
            ),
          ),
      ],
    );
  }

  Widget _buildOdPane(ColorScheme cs) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppCard.outlined(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.space16,
            vertical: AppTheme.space16,
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Pressable(
                      onTap: _pickOrigin,
                      child: _FieldColumn(
                        label: AppI18n.of(context).railOrigin,
                        value: _originName,
                        placeholder: _stationPlaceholder(AppI18n.of(context)),
                        crossAxisAlignment: CrossAxisAlignment.start,
                      ),
                    ),
                  ),
                  Pressable(
                    onTap: _swap,
                    // 18px icon + 8px padding = 34px painted size; widen the
                    // hit target only, per the 44px touch-target floor.
                    minTapSize: 44,
                    child: Container(
                      padding: const EdgeInsets.all(AppTheme.space8),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerLow,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.swap_horiz_rounded,
                        size: 18,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Pressable(
                      onTap: _pickDest,
                      child: _FieldColumn(
                        label: AppI18n.of(context).railDestination,
                        value: _destName,
                        placeholder: _stationPlaceholder(AppI18n.of(context)),
                        crossAxisAlignment: CrossAxisAlignment.end,
                      ),
                    ),
                  ),
                ],
              ),
              _cardDivider(cs),
              Row(
                children: [
                  Expanded(
                    child: Pressable(
                      onTap: _pickDate,
                      child: _FieldColumn(
                        label: AppI18n.of(context).commonDate,
                        value: _formatDateDisplay(
                          AppI18n.of(context),
                          _selectedDate,
                        ),
                        crossAxisAlignment: CrossAxisAlignment.start,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Pressable(
                      onTap: () async {
                        final picked = await AppTimePicker.show(
                          context,
                          _selectedTime,
                        );
                        if (picked != null && mounted) {
                          setState(() => _selectedTime = picked);
                        }
                      },
                      child: _FieldColumn(
                        label: AppI18n.of(context).commonTime,
                        value: _formatTime(_selectedTime),
                        crossAxisAlignment: CrossAxisAlignment.end,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppTheme.space16),
        AppSlidingSegment<bool>(
          options: {
            true: AppI18n.of(context).goDepartAt,
            false: AppI18n.of(context).goArriveBy,
          },
          value: _isDepartureTime,
          onChanged: (value) => setState(() => _isDepartureTime = value),
        ),
        const SizedBox(height: AppTheme.space16),
        _SubmitButton(
          enabled: _originName.isNotEmpty && _destName.isNotEmpty,
          onTap: _submitOd,
        ),
      ],
    );
  }

  Widget _buildTrainPane(ColorScheme cs) {
    final trainNoEntered = _trainController.text.trim().isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppCard.outlined(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.space16,
            vertical: AppTheme.space16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppI18n.of(context).railTrainNumber,
                style: AppTextStyles.bodyVerySmall.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: AppTheme.space6),
              TextField(
                controller: _trainController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                // Same style as a [_FieldColumn] value, so this card is
                // exactly as tall as the O/D card and switching mode does not
                // shove everything below it up or down.
                style: _fieldValueStyle.copyWith(color: cs.onSurface),
                cursorColor: cs.primary,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: AppI18n.of(context).railTrainNumberHint,
                  hintStyle: _fieldValueStyle.copyWith(color: cs.outline),
                ),
              ),
              _cardDivider(cs),
              Pressable(
                onTap: _pickDate,
                child: _FieldColumn(
                  label: AppI18n.of(context).commonDate,
                  value: _formatDateDisplay(AppI18n.of(context), _selectedDate),
                  crossAxisAlignment: CrossAxisAlignment.start,
                ),
              ),
            ],
          ),
        ),
        if (_recentQueries.isNotEmpty) ...[
          const SizedBox(height: AppTheme.space16),
          Text(
            AppI18n.of(context).railRecentQueries,
            style: AppTextStyles.bodyVerySmall.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: AppTheme.space8),
          Wrap(
            spacing: AppTheme.space8,
            runSpacing: AppTheme.space8,
            children: [
              for (final query in _recentQueries)
                _RecentTrainChip(
                  system: (query['system'] as String?) ?? 'tra',
                  trainNo: (query['trainNo'] as String?) ?? '',
                  onTap: _fillFromRecent,
                ),
            ],
          ),
        ],
        const SizedBox(height: AppTheme.space16),
        _SubmitButton(enabled: trainNoEntered, onTap: _submitTrain),
        if (!trainNoEntered) ...[
          const SizedBox(height: AppTheme.space8),
          Text(
            AppI18n.of(context).railTrainNumberPrompt,
            style: AppTextStyles.bodyVerySmall.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _cardDivider(ColorScheme cs) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppTheme.space12),
    child: Divider(
      color: cs.outlineVariant.withValues(alpha: 0.4),
      height: 1,
    ),
  );
}

class _FieldColumn extends StatelessWidget {
  const _FieldColumn({
    required this.label,
    required this.value,
    required this.crossAxisAlignment,
    this.placeholder,
  });

  final String label;
  final String value;
  final CrossAxisAlignment crossAxisAlignment;

  /// Stand-in rendered in the outline colour when [value] is empty, so an
  /// unpicked station reads as a prompt rather than as a chosen one.
  final String? placeholder;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: crossAxisAlignment,
      children: [
        Text(
          label,
          style: AppTextStyles.bodyVerySmall.copyWith(
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: AppTheme.space6),
        Text(
          value.isEmpty ? (placeholder ?? value) : value,
          style: _fieldValueStyle.copyWith(
            color: value.isEmpty ? cs.outline : cs.onSurface,
          ),
        ),
      ],
    );
  }
}

class _RecentTrainChip extends StatelessWidget {
  const _RecentTrainChip({
    required this.system,
    required this.trainNo,
    required this.onTap,
  });

  final String system;
  final String trainNo;
  final void Function(String system, String trainNo) onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isThsr = system == 'thsr';
    return Pressable(
      onTap: () => onTap(system, trainNo),
      // Chip content is far short of 44px on its own; widen the hit target
      // without inflating the visual chip.
      minTapSize: 44,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.space12,
          vertical: AppTheme.space8,
        ),
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(AppTheme.radiusStadium),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isThsr
                  ? AppI18n.of(context).modeThsr
                  : AppI18n.of(context).modeTra,
              style: AppTextStyles.bodySmall.copyWith(
                color: isThsr ? AppTheme.trainThsr : cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: AppTheme.space6),
            Text(
              trainNo,
              style: AppTextStyles.memo.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
                fontFeatures: _tnum,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubmitButton extends StatelessWidget {
  const _SubmitButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Pressable(
      onTap: enabled ? onTap : null,
      semanticLabel: AppI18n.of(context).commonQuery,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          // cs.outline/cs.surface (the old pair) sits at 1.72:1, well under
          // WCAG AA. outlineVariant/onSurfaceVariant clears 4.5:1 while still
          // reading as disabled.
          color: enabled ? cs.primary : cs.outlineVariant,
          borderRadius: BorderRadius.circular(AppTheme.radiusButton),
        ),
        alignment: Alignment.center,
        child: Text(
          AppI18n.of(context).commonQuery,
          style: AppTextStyles.bodyRegular.copyWith(
            color: enabled ? cs.onPrimary : cs.onSurfaceVariant,
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}

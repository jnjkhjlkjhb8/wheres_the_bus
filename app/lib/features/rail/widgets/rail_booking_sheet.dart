import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/features/rail/booking_launch.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_sliding_segment.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';
import 'package:wheres_the_bus/shared/widgets/train_type_chip.dart';

Future<void> showRailBookingSheet(
  BuildContext context,
  RailBookingRequest request, {
  String trainType = '',
  bool hasBikeService = false,
}) {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: cs.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppTheme.radiusBottomSheet),
      ),
    ),
    builder: (_) => _RailBookingSheet(
      request: request,
      trainType: trainType,
      hasBikeService: hasBikeService,
    ),
  );
}

/// TRA booking classes this train actually offers. 騰雲座艙 exists only on
/// 新自強 (EMU3000) and 兩鐵 only on trains that carry bicycles, so offering
/// either elsewhere would send a class the booking system rejects.
List<TraBookingClass> traClassesFor({
  required String trainType,
  required bool hasBikeService,
}) => [
  TraBookingClass.standard,
  // Compared as a class, not as its name: the label is localized, so matching
  // on the words would stop offering Tengyun in every other locale.
  if (TrainType.of(trainType) == TrainType.newTzeChiang)
    TraBookingClass.tengyun,
  if (hasBikeService) TraBookingClass.bikeOnboard,
];

class _RailBookingSheet extends StatefulWidget {
  const _RailBookingSheet({
    required this.request,
    required this.trainType,
    required this.hasBikeService,
  });

  final RailBookingRequest request;
  final String trainType;
  final bool hasBikeService;

  @override
  State<_RailBookingSheet> createState() => _RailBookingSheetState();
}

class _RailBookingSheetState extends State<_RailBookingSheet> {
  late RailBookingRequest _request = widget.request;

  /// The prefetched deeplink, and the options it was minted for. TDX signs the
  /// URL over the booking parameters, so a prefetch is only valid while the
  /// user's choices are unchanged.
  String? _url;
  RailBookingRequest? _urlFor;
  bool _loading = false;
  bool _exchangeFailed = false;
  bool _appInstalled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_probeApp());
    unawaited(_prefetch());
  }

  Future<void> _probeApp() async {
    final installed = await isOperatorAppInstalled(isThsr: _request.isThsr);
    if (mounted && installed) setState(() => _appInstalled = true);
  }

  /// Warms the deeplink for the current options. Failures are silent here: the
  /// user has not asked for anything yet, so this only ever costs them nothing.
  Future<void> _prefetch() async {
    final target = _request;
    final url = await fetchRailBookingUrl(target, useApp: false);
    if (!mounted || url == null) return;
    setState(() {
      _url = url;
      _urlFor = target;
    });
  }

  /// Applies an option change and drops a deeplink minted for the old options.
  void _update(RailBookingRequest next) {
    setState(() {
      _request = next;
      _url = null;
      _urlFor = null;
      _exchangeFailed = false;
    });
    unawaited(_prefetch());
  }

  bool get _hasFreshUrl => _url != null && _urlFor == _request;

  Future<void> _book({bool useApp = false}) async {
    // The app variant takes no ticket parameters, so its URL is never the one
    // prefetched for the web variant.
    var url = useApp ? null : (_hasFreshUrl ? _url : null);
    if (url == null) {
      setState(() => _loading = true);
      url = await fetchRailBookingUrl(_request, useApp: useApp);
      if (!mounted) return;
      setState(() => _loading = false);
      if (url == null) {
        // Opening an unfilled booking page without saying so is what made this
        // look broken; surface it and let the user decide.
        setState(() => _exchangeFailed = true);
        return;
      }
    }
    final result = await openRailBooking(url: url, isThsr: _request.isThsr);
    if (!mounted) return;
    if (result == BookingLaunchResult.failed) {
      setState(() => _exchangeFailed = true);
      return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _bookUnfilled() async {
    await openRailBooking(url: null, isThsr: _request.isThsr);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final operator = _request.isThsr ? '高鐵' : '台鐵';
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetDragHandle(),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.space20,
                AppTheme.space10,
                AppTheme.space20,
                AppTheme.space4,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_request.isThsr) ..._thsrOptions() else ..._traOptions(),
                  const SizedBox(height: 18),
                  _SheetSection(
                    title: AppI18n.of(context).railBookingNotes,
                    child: _Notes(
                      lines: _request.isThsr
                          ? [
                              AppI18n.of(context).railBookingPayNote,
                              AppI18n.of(context).railBookingIdNote,
                              AppI18n.of(context).railBookingThsrFareNote,
                            ]
                          : [
                              AppI18n.of(context).railBookingTraCategoryNote,
                              AppI18n.of(context).railBookingPayNote,
                              AppI18n.of(context).railBookingTraFareNote,
                            ],
                    ),
                  ),
                  if (_appInstalled) ...[
                    const SizedBox(height: 18),
                    _SheetSection(
                      title: AppI18n.of(context).railBookingOpenWith,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _GhostButton(
                            label: AppI18n.of(
                              context,
                            ).railOpenOperatorApp(operator),
                            onTap: _loading ? null : () => _book(useApp: true),
                          ),
                          const SizedBox(height: AppTheme.space6),
                          Text(
                            AppI18n.of(context).railBookingAppNoCount,
                            style: AppTextStyles.bodyVerySmall.copyWith(
                              color: cs.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_exchangeFailed) ...[
                    const SizedBox(height: 18),
                    _FailureNotice(onOpenAnyway: _bookUnfilled),
                  ],
                ],
              ),
            ),
          ),
          _Footer(
            request: _request,
            loading: _loading,
            operator: operator,
            onBook: _request.ticketTotal > 0 && !_loading ? _book : null,
          ),
        ],
      ),
    );
  }

  List<Widget> _thsrOptions() => [
    _SheetSection(
      title: AppI18n.of(context).railBookingCarClass,
      child: AppSlidingSegment<bool>(
        options: {
          false: AppI18n.of(context).railBookingStandard,
          true: AppI18n.of(context).railBookingBusiness,
        },
        value: _request.business,
        onChanged: (business) => _update(_request.copyWith(business: business)),
      ),
    ),
    const SizedBox(height: 18),
    _SheetSection(
      title: AppI18n.of(context).railBookingTicketCount,
      child: Column(
        children: [
          for (final category in TicketCategory.values)
            _StepperRow(
              name: category.labelOf(AppI18n.of(context)),
              hint: _categoryHint(AppI18n.of(context), category),
              value: _request.tickets[category] ?? 0,
              max: kMaxTicketsPerCategory,
              // Zero is a valid count per category; only the order total has to
              // be non-empty, and the CTA enforces that.
              min: 0,
              showDivider: category != TicketCategory.values.last,
              onChanged: (value) => _update(
                _request.copyWith(
                  tickets: {..._request.tickets, category: value},
                ),
              ),
            ),
        ],
      ),
    ),
  ];

  List<Widget> _traOptions() {
    final classes = traClassesFor(
      trainType: widget.trainType,
      hasBikeService: widget.hasBikeService,
    );
    return [
      // A lone 一般訂票 is not a choice, so the section disappears rather than
      // presenting a radio group with one option.
      if (classes.length > 1) ...[
        _SheetSection(
          title: AppI18n.of(context).railBookingCategory,
          child: Column(
            children: [
              for (final option in classes)
                _ChoiceRow(
                  name: option.labelOf(AppI18n.of(context)),
                  hint: _traClassHint(AppI18n.of(context), option),
                  selected: _request.traClass == option,
                  showDivider: option != classes.last,
                  onTap: () => _update(_request.copyWith(traClass: option)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 18),
      ],
      _SheetSection(
        title: AppI18n.of(context).railBookingQuantity,
        child: _StepperRow(
          name: AppI18n.of(context).railBookingTicketNoun,
          hint: AppI18n.of(context).railMaxTicketsHint(kMaxTraTickets),
          value: _request.traCount,
          max: kMaxTraTickets,
          min: 1,
          showDivider: false,
          onChanged: (value) => _update(_request.copyWith(traCount: value)),
        ),
      ),
    ];
  }
}

String? _categoryHint(AppI18n i18n, TicketCategory category) =>
    switch (category) {
      TicketCategory.child => i18n.railBookingChildNote,
      TicketCategory.disabled => i18n.railBookingIdRequired,
      TicketCategory.senior => i18n.railBookingSeniorNote,
      TicketCategory.student => i18n.railBookingIdRequired,
      TicketCategory.adult => null,
    };

String? _traClassHint(AppI18n i18n, TraBookingClass option) => switch (option) {
  TraBookingClass.tengyun => i18n.railBookingTengyunNote,
  TraBookingClass.bikeOnboard => i18n.railBookingBikeNote,
  TraBookingClass.standard => null,
};

/// A labelled group. The label is a quiet caption, not a heading: the sheet is
/// a short form, and competing headings would flatten its one real hierarchy.
class _SheetSection extends StatelessWidget {
  const _SheetSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: AppTextStyles.bodyVerySmall.copyWith(
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppTheme.space10),
        child,
      ],
    );
  }
}

class _StepperRow extends StatelessWidget {
  const _StepperRow({
    required this.name,
    required this.value,
    required this.min,
    required this.max,
    required this.showDivider,
    required this.onChanged,
    this.hint,
  });

  final String name;
  final String? hint;
  final int value;
  final int min;
  final int max;
  final bool showDivider;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: showDivider
          ? BoxDecoration(
              border: Border(bottom: BorderSide(color: cs.outlineVariant)),
            )
          : null,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: AppTextStyles.bodyRegular.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (hint != null)
                  Text(
                    hint!,
                    style: AppTextStyles.bodyVerySmall.copyWith(
                      color: cs.outline,
                    ),
                  ),
              ],
            ),
          ),
          _StepButton(
            icon: Icons.remove_rounded,
            semanticLabel: AppI18n.of(context).stepperDecrease(name),
            onTap: value > min ? () => onChanged(value - 1) : null,
          ),
          SizedBox(
            width: 34,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              // A zero count recedes; it is an untouched default, not a number
              // the user chose.
              style: AppTextStyles.timeValue(
                size: 15,
                weight: value == 0 ? FontWeight.w400 : FontWeight.w600,
                color: value == 0 ? cs.outline : cs.onSurface,
              ),
            ),
          ),
          _StepButton(
            icon: Icons.add_rounded,
            semanticLabel: AppI18n.of(context).stepperIncrease(name),
            onTap: value < max ? () => onChanged(value + 1) : null,
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return Pressable(
      onTap: onTap,
      enabled: enabled,
      semanticLabel: semanticLabel,
      // Chrome stays 30px; only the hit area grows to the 44px floor.
      minTapSize: 44,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(AppTheme.radiusButton),
        ),
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: 17,
          color: enabled ? cs.onSurface : cs.outline,
        ),
      ),
    );
  }
}

/// One option in a single-choice list. A list, not a segmented control: two of
/// the three options need a line of explanation, which a segment would clip.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.name,
    required this.selected,
    required this.showDivider,
    required this.onTap,
    this.hint,
  });

  final String name;
  final String? hint;
  final bool selected;
  final bool showDivider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: selected,
      child: Pressable(
        onTap: onTap,
        semanticLabel: name,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: showDivider
              ? BoxDecoration(
                  border: Border(bottom: BorderSide(color: cs.outlineVariant)),
                )
              : null,
          child: Row(
            children: [
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? cs.primary : cs.outline,
                    // A thick ring reads as filled without a second element to
                    // centre inside it.
                    width: selected ? 5 : 1.5,
                  ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: AppTextStyles.bodyRegular.copyWith(
                        color: cs.onSurface,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                    if (hint != null)
                      Text(
                        hint!,
                        style: AppTextStyles.bodyVerySmall.copyWith(
                          color: cs.outline,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Notes extends StatelessWidget {
  const _Notes({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    top: 7,
                    right: AppTheme.space8,
                    left: 3,
                  ),
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.outline,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    line,
                    style: AppTextStyles.bodySmall.copyWith(
                      color: cs.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Shown when the exchange failed. The plain booking site is still one tap
/// away, but the user is told what they are about to get.
class _FailureNotice extends StatelessWidget {
  const _FailureNotice({required this.onOpenAnyway});

  final VoidCallback onOpenAnyway;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppTheme.space12),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusButton),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppI18n.of(context).railBookingNoTrainNote,
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onErrorContainer,
              height: 1.5,
            ),
          ),
          const SizedBox(height: AppTheme.space10),
          _GhostButton(
            label: AppI18n.of(context).railBookingOpenAnyway,
            onTap: onOpenAnyway,
          ),
        ],
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return Pressable(
      onTap: onTap,
      enabled: enabled,
      semanticLabel: label,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(AppTheme.radiusButton),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: AppTextStyles.bodyRegular.copyWith(
            color: enabled ? cs.onSurface : cs.outline,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.request,
    required this.loading,
    required this.operator,
    required this.onBook,
  });

  final RailBookingRequest request;
  final bool loading;
  final String operator;
  final VoidCallback? onBook;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = onBook != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space20,
        AppTheme.space12,
        AppTheme.space20,
        AppTheme.space16,
      ),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                AppI18n.of(context).railTicketTotal(request.ticketTotal),
                style: AppTextStyles.bodySmall.copyWith(
                  color: cs.onSurfaceVariant,
                  fontFeatures: AppTextStyles.tabularFigures,
                ),
              ),
              const Spacer(),
              // The last anchor on what is being booked, at the moment of
              // committing to it.
              Text(
                '${request.origin} → ${request.destination}',
                style: AppTextStyles.memo.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.space8),
          Pressable(
            onTap: onBook,
            enabled: enabled,
            semanticLabel: AppI18n.of(context).railBookingGoSemantics,
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                color: enabled ? cs.primary : cs.outlineVariant,
                borderRadius: BorderRadius.circular(AppTheme.radiusButton),
              ),
              alignment: Alignment.center,
              child: loading
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: cs.onPrimary,
                          ),
                        ),
                        const SizedBox(width: AppTheme.space8),
                        Text(
                          AppI18n.of(context).railBookingPreparing,
                          style: AppTextStyles.bodyRegular.copyWith(
                            color: cs.onPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    )
                  : Text(
                      AppI18n.of(context).railBookingGoSemantics,
                      style: AppTextStyles.bodyRegular.copyWith(
                        color: enabled ? cs.onPrimary : cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: AppTheme.space8),
        ],
      ),
    );
  }
}

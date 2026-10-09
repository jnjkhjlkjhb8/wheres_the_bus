import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/app/theme/notice_tone.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_event.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_state.dart';
import 'package:wheres_the_bus/features/alerts/view/alert_source_chip.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_snackbar.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';
import 'package:wheres_the_bus/shared/widgets/divider_line.dart';

/// One inbox entry: either a group heading or a notice row. Built as a flat
/// list so the two groups scroll as one surface — a rider scanning for 「is
/// anything broken」 reads top-down, not through two nested scroll views.
sealed class _Entry {
  const _Entry();
}

class _GroupHeading extends _Entry {
  const _GroupHeading(this.label, this.count);

  final String label;
  final int count;
}

class _NoticeEntry extends _Entry {
  const _NoticeEntry(this.notice);

  final AlertViewModel notice;
}

Future<void> showNotificationSheet(BuildContext context) async {
  final bloc = context.read<AlertBloc>();
  final unreadAtOpen = bloc.state.unreadAlerts.map((a) => a.message).toSet();
  bloc.add(const AlertAllRead());
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => BlocProvider.value(
      value: bloc,
      child: _NotificationSheet(unreadAtOpen: unreadAtOpen),
    ),
  );
}

class _NotificationSheet extends StatelessWidget {
  const _NotificationSheet({required this.unreadAtOpen});

  final Set<String> unreadAtOpen;

  void _dismiss(BuildContext context, AlertViewModel alert) {
    context.read<AlertBloc>().add(AlertDismissed(alert.message));
    _showUndo(context, [alert.message], AppI18n.of(context).alertsCleared);
  }

  void _clearAll(BuildContext context, List<AlertViewModel> alerts) {
    final messages = alerts.map((a) => a.message).toList();
    context.read<AlertBloc>().add(AlertAllDismissed(messages));
    _showUndo(
      context,
      messages,
      AppI18n.of(context).alertsClearedCount(messages.length),
    );
  }

  void _showUndo(BuildContext context, List<String> messages, String label) {
    final bloc = context.read<AlertBloc>();
    AppSnackbar.show(
      context,
      label,
      action: AppI18n.of(context).commonUndo,
      onAction: () => bloc.add(AlertRestored(messages)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    return Container(
      height: media.size.height * 0.72,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusBottomSheet),
        ),
      ),
      child: BlocBuilder<AlertBloc, AlertState>(
        builder: (context, state) {
          // Newest first within each group; 進行中 always above 訊息, because
          // a disruption happening now outranks anything there is to read.
          final ongoing = state.ongoingNotices.reversed.toList();
          final messages = state.messageNotices.reversed.toList();
          final alerts = [...ongoing, ...messages];
          final entries = <_Entry>[
            if (ongoing.isNotEmpty)
              _GroupHeading(
                AppI18n.of(context).alertsGroupOngoing,
                ongoing.length,
              ),
            ...ongoing.map(_NoticeEntry.new),
            if (messages.isNotEmpty)
              _GroupHeading(
                AppI18n.of(context).alertsGroupMessages,
                messages.length,
              ),
            ...messages.map(_NoticeEntry.new),
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SheetDragHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTheme.space20,
                  AppTheme.space4,
                  AppTheme.space12,
                  AppTheme.space8,
                ),
                child: Row(
                  children: [
                    Text(
                      AppI18n.of(context).alertsTitle,
                      style: AppTextStyles.heading2.copyWith(
                        color: cs.onSurface,
                      ),
                    ),
                    const Spacer(),
                    if (alerts.isNotEmpty)
                      Pressable(
                        onTap: () => _clearAll(context, alerts),
                        semanticLabel: AppI18n.of(
                          context,
                        ).alertsClearAllSemantics,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppTheme.space12,
                            vertical: AppTheme.space8,
                          ),
                          child: Text(
                            AppI18n.of(context).alertsClearAll,
                            style: AppTextStyles.bodyRegular.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const DividerLine(),
              Expanded(
                child: entries.isEmpty
                    ? const _NotificationEmpty()
                    : ListView.builder(
                        padding: const EdgeInsets.only(
                          bottom: AppTheme.space24,
                        ),
                        itemCount: entries.length,
                        itemBuilder: (context, i) => switch (entries[i]) {
                          final _GroupHeading heading => _GroupHeader(
                            label: heading.label,
                            count: heading.count,
                          ),
                          final _NoticeEntry entry => _DismissibleRow(
                            notice: entry.notice,
                            unread: unreadAtOpen.contains(
                              entry.notice.message,
                            ),
                            onDismissed: () => _dismiss(context, entry.notice),
                          ),
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Group heading. Sticky would fight the sheet's own drag, so it scrolls with
/// the list and leans on the count to stay readable when it drifts off.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space20,
        AppTheme.space16,
        AppTheme.space20,
        AppTheme.space6,
      ),
      child: Row(
        spacing: AppTheme.space8,
        children: [
          Text(
            label,
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            '$count',
            style: AppTextStyles.memo.copyWith(
              fontSize: 11.5,
              color: cs.outline,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Wraps a row in swipe-to-clear, except where the notice may not be cleared.
class _DismissibleRow extends StatelessWidget {
  const _DismissibleRow({
    required this.notice,
    required this.unread,
    required this.onDismissed,
  });

  final AlertViewModel notice;
  final bool unread;
  final VoidCallback onDismissed;

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey(notice.message),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDismissed(),
      background: _DismissBackground(),
      child: _NotificationRow(alert: notice, unread: unread),
    );
  }
}

class _NotificationRow extends StatefulWidget {
  const _NotificationRow({required this.alert, required this.unread});

  final AlertViewModel alert;
  final bool unread;

  @override
  State<_NotificationRow> createState() => _NotificationRowState();
}

class _NotificationRowState extends State<_NotificationRow> {
  bool _expanded = false;

  void _toggle() {
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final alert = widget.alert;
    final unread = widget.unread;
    final colors = noticeColors(alert.tone, cs);
    final isRed = alert.tone == NoticeTone.critical;
    final dotColor = isRed ? colors.accent : cs.onSurfaceVariant;

    // A critical row is tinted end-to-end; the old colored left stripe is
    // gone. Every other tone stays on the plain surface — the chip and the
    // group it sits in already say what it is.
    final background = isRed
        ? Color.alphaBlend(colors.accent.withValues(alpha: 0.05), cs.surface)
        : cs.surface;

    final titleText = alert.title ?? alert.message;
    // When there is a distinct title, [message] becomes the body; otherwise the
    // message already reads as the title and a body line would duplicate it.
    final bodyText = alert.title != null ? alert.message : null;
    final clampTarget = bodyText ?? titleText;

    final time = alert.time;
    final now = DateTime.now();

    return LayoutBuilder(
      builder: (context, constraints) {
        // The text column is narrower than the row: 20px padding each side
        // plus the trailing dot/chevron slot (12px gap + up to 18px icon).
        final textWidth = (constraints.maxWidth - 40 - 30).clamp(
          0.0,
          double.infinity,
        );
        final overflows = _overflows(
          context,
          clampTarget,
          bodyText != null ? _bodyStyle(cs) : _titleStyle(cs, unread),
          textWidth,
        );
        final canExpand = overflows || time != null;

        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AlertSourceChip(
                  source: alert.source,
                  department: alert.department,
                ),
                if (alert.source != null && isRed)
                  const SizedBox(width: AppTheme.space8),
                if (isRed) _SeverityTag(accent: colors.accent, cs: cs),
                const Spacer(),
                if (time != null)
                  Text(
                    alertRelativeTime(AppI18n.of(context), time, now),
                    style: AppTextStyles.memo.copyWith(
                      fontSize: 11.5,
                      color: cs.onSurfaceVariant,
                      height: 1,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppTheme.space8),
            Text(
              titleText,
              maxLines: bodyText == null && !_expanded ? 2 : null,
              overflow: bodyText == null && !_expanded
                  ? TextOverflow.ellipsis
                  : TextOverflow.clip,
              style: _titleStyle(cs, unread),
            ),
            if (bodyText != null) ...[
              const SizedBox(height: AppTheme.space4),
              Text(
                bodyText,
                maxLines: _expanded ? null : 2,
                overflow: _expanded ? TextOverflow.clip : TextOverflow.ellipsis,
                style: _bodyStyle(cs),
              ),
            ],
            if (_expanded && time != null) ...[
              const SizedBox(height: AppTheme.space8),
              Text(
                _publishFooter(AppI18n.of(context), alert),
                style: AppTextStyles.memo.copyWith(
                  fontSize: 11.5,
                  color: cs.outline,
                  height: 1,
                ),
              ),
            ],
          ],
        );

        return Pressable(
          onTap: canExpand ? _toggle : null,
          child: AnimatedSize(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : AppMotion.short,
            curve: AppMotion.easeOut,
            alignment: Alignment.topCenter,
            child: Container(
              decoration: BoxDecoration(
                color: background,
                border: Border(
                  top: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.space20,
                vertical: AppTheme.space16,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: content),
                  if (unread) ...[
                    const SizedBox(width: AppTheme.space12),
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(top: AppTheme.space4),
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ] else if (canExpand) ...[
                    const SizedBox(width: AppTheme.space12),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: cs.outline,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  TextStyle _titleStyle(ColorScheme cs, bool unread) =>
      AppTextStyles.bodyRegular.copyWith(
        fontSize: 15,
        color: cs.onSurface,
        fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
        height: 1.4,
      );

  TextStyle _bodyStyle(ColorScheme cs) => AppTextStyles.bodyRegular.copyWith(
    fontSize: 13.5,
    color: cs.onSurfaceVariant,
    height: 1.5,
  );

  /// 「發布 HH:mm」, plus the operator code when the source carries one.
  String _publishFooter(AppI18n i18n, AlertViewModel alert) {
    final t = alert.time!;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final code = alert.source?.code ?? '';
    final suffix = code.isEmpty ? '' : ' · $code';
    return i18n.alertPublishedAt('$hh:$mm', suffix);
  }

  /// Whether [text] in [style] would exceed two lines at [maxWidth].
  bool _overflows(
    BuildContext context,
    String text,
    TextStyle style,
    double maxWidth,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 2,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    return painter.didExceedMaxLines;
  }
}

/// Inline 「服務中斷」 tag next to the source chip on red rows.
class _SeverityTag extends StatelessWidget {
  const _SeverityTag({required this.accent, required this.cs});

  final Color accent;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.space6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusChip),
        border: Border.all(color: accent.withValues(alpha: 0.4)),
      ),
      child: Text(
        AppI18n.of(context).alertsDisruption,
        style: TextStyle(
          fontFamily: 'IBMPlexSans',
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          height: 1,
          color: accent,
        ),
      ),
    );
  }
}

class _DismissBackground extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surfaceContainerHighest,
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: AppTheme.space24),
      child: Icon(
        Icons.delete_outline_rounded,
        size: 22,
        color: cs.onSurfaceVariant,
      ),
    );
  }
}

class UnreadBadge extends StatelessWidget {
  const UnreadBadge({required this.count, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: cs.error,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: cs.surface, width: 2),
      ),
      child: Center(
        child: Text(
          count > 9 ? '9+' : '$count',
          style: AppTextStyles.bodyVerySmall.copyWith(
            color: cs.onError,
            fontWeight: FontWeight.bold,
            height: 1,
          ),
        ),
      ),
    );
  }
}

class _NotificationEmpty extends StatelessWidget {
  const _NotificationEmpty();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.notifications_none_rounded,
            size: 44,
            color: cs.outline,
          ),
          const SizedBox(height: AppTheme.space14),
          Text(
            AppI18n.of(context).alertsEmpty,
            style: AppTextStyles.bodyLarge.copyWith(
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: AppTheme.space4),
          Text(
            AppI18n.of(context).alertsEmptyHint,
            style: AppTextStyles.bodySmall.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

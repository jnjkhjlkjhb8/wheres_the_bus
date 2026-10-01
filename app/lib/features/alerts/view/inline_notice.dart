import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/app/theme/notice_tone.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_state.dart';
import 'package:wheres_the_bus/features/alerts/view/alert_source_chip.dart';
import 'package:wheres_the_bus/features/alerts/view/notification_sheet.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

class InlineNotice extends StatelessWidget {
  const InlineNotice({
    required this.routeType,
    required this.routeKeys,
    super.key,
  });

  /// Domain of the page: `bus`, `mrt`, `tra`, `thsr`.
  final String routeType;

  /// The identities this page is about — bus SubRouteUIDs, TRA train numbers,
  /// metro line codes. Empty matches only system-wide notices.
  final Set<String> routeKeys;

  bool _isAbout(AlertViewModel notice) {
    if (notice.routeType != routeType) return false;
    return notice.routeKeys.isEmpty || notice.routeKeys.any(routeKeys.contains);
  }

  @override
  Widget build(BuildContext context) {
    return BlocSelector<AlertBloc, AlertState, AlertViewModel?>(
      selector: (state) {
        final matches = state.contextualNotices.where(_isAbout).toList();
        // Critical outranks caution; within a tone the newest wins, since the
        // feed appends and a later notice supersedes an earlier one.
        return matches.where((n) => n.tone == NoticeTone.critical).lastOrNull ??
            matches.lastOrNull;
      },
      // Column(min) so the card hugs its content wherever it is dropped: a
      // parent that hands down a tight height (a Stack child, a sized slot)
      // would otherwise stretch the notice to fill the screen.
      builder: (context, notice) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSize(
            duration: AppMotion.reduced(context)
                ? AppMotion.instant
                : AppMotion.medium,
            curve: AppMotion.easeOut,
            alignment: Alignment.topCenter,
            child: notice == null
                ? const SizedBox(width: double.infinity)
                : _NoticeCard(notice: notice),
          ),
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.notice});

  final AlertViewModel notice;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final colors = noticeColors(notice.tone, cs);
    final time = notice.time;
    final footer = time == null
        ? AppI18n.of(context).commonTapForDetails
        : AppI18n.of(context).alertTimeAndDetails(
            alertRelativeTime(AppI18n.of(context), time, DateTime.now()),
          );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space12,
        AppTheme.space10,
        AppTheme.space12,
        0,
      ),
      child: Pressable(
        onTap: () => unawaited(showNotificationSheet(context)),
        semanticLabel: notice.title ?? notice.message,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.space12,
            vertical: AppTheme.space10,
          ),
          decoration: BoxDecoration(
            color: colors.background,
            borderRadius: BorderRadius.circular(AppTheme.radiusCard),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 9,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  notice.tone == NoticeTone.critical
                      ? Icons.warning_amber_rounded
                      : Icons.info_outline_rounded,
                  size: 16,
                  color: colors.accent,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notice.title ?? notice.message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyRegular.copyWith(
                        fontSize: 13.5,
                        color: colors.ink,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: AppTheme.space2),
                    Text(
                      footer,
                      style: AppTextStyles.memo.copyWith(
                        fontSize: 11,
                        color: colors.ink.withValues(alpha: 0.8),
                        height: 1.2,
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

part of '../view/metro_station_detail_view.dart';

/// Whether metro service is currently running, has ended for the day, or has
/// not yet started (pre-dawn), derived from the first/last-train schedule.
enum MetroServiceState { running, ended, beforeFirst }

class MetroServiceStatus {
  const MetroServiceStatus({
    required this.state,
    this.lastTrain,
    this.firstTrain,
    this.firstDestination,
  });

  final MetroServiceState state;

  /// `HH:MM` of the latest last train across destinations (for the ended card).
  final String? lastTrain;

  /// `HH:MM` of the earliest next first train and its destination.
  final String? firstTrain;
  final String? firstDestination;
}

int? _parseHm(String value) {
  final parts = value.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return h * 60 + m;
}

/// Derives the service state at [now] from [schedule]. Times before 03:00 are
/// treated as belonging to the previous service day (+24h) so past-midnight
/// last trains (e.g. 00:40) compare correctly against an evening `now`.
MetroServiceStatus metroServiceStatus(
  List<MetroSchedule> schedule,
  DateTime now,
) {
  int adjust(int minutes) => minutes < 180 ? minutes + 1440 : minutes;

  int? earliestFirst;
  String? firstHm;
  String? firstDest;
  int? latestLast;
  String? lastHm;

  for (final s in schedule) {
    final f = _parseHm(s.firstTime);
    if (f != null && (earliestFirst == null || f < earliestFirst)) {
      earliestFirst = f;
      firstHm = s.firstTime;
      firstDest = s.destination;
    }
    final l = _parseHm(s.lastTime);
    if (l != null) {
      final la = adjust(l);
      if (latestLast == null || la > latestLast) {
        latestLast = la;
        lastHm = s.lastTime;
      }
    }
  }

  if (earliestFirst == null || latestLast == null) {
    return const MetroServiceStatus(state: MetroServiceState.running);
  }

  final nowAdj = adjust(now.hour * 60 + now.minute);
  final MetroServiceState state;
  if (nowAdj > latestLast) {
    state = MetroServiceState.ended;
  } else if (nowAdj < earliestFirst) {
    state = MetroServiceState.beforeFirst;
  } else {
    state = MetroServiceState.running;
  }

  return MetroServiceStatus(
    state: state,
    lastTrain: lastHm,
    firstTrain: firstHm,
    firstDestination: firstDest,
  );
}

/// Empty-arrivals content: a filled card that names why there are no trains
/// (service ended / not yet started) and the next first train, or a quiet line
/// when service is running but no live estimate is available.
class MetroArrivalsEmpty extends StatelessWidget {
  const MetroArrivalsEmpty({
    required this.schedule,
    this.now,
    this.onRetry,
    super.key,
  });

  final List<MetroSchedule> schedule;

  /// Injectable clock for tests; defaults to [DateTime.now].
  final DateTime? now;

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final status = schedule.isEmpty
        ? const MetroServiceStatus(state: MetroServiceState.running)
        : metroServiceStatus(schedule, now ?? DateTime.now());

    if (status.state == MetroServiceState.running) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTheme.space8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              AppI18n.of(context).metroEtaUnavailable,
              style: AppTextStyles.bodyRegular.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              AppI18n.of(context).metroEtaUnavailableBody,
              style: AppTextStyles.bodySmall.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: AppTheme.space8),
              // A recovery hint, not the primary action on the screen — plain
              // text per the design system's Text/Tertiary style, not a
              // filled button.
              Pressable(
                onTap: onRetry,
                semanticLabel: AppI18n.of(context).commonReload,
                child: Text(
                  AppI18n.of(context).commonReload,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    final i18n = AppI18n.of(context);
    final ended = status.state == MetroServiceState.ended;
    final title = ended
        ? AppI18n.of(context).metroServiceEnded
        : AppI18n.of(context).metroServiceNotStarted;
    final subtitle = ended && status.lastTrain != null
        ? i18n.metroLastTrainDeparted(status.lastTrain!)
        : null;
    final nextPrefix = ended
        ? i18n.metroFirstTrainTomorrow
        : i18n.metroFirstTrainToday;
    final nextLabel = status.firstDestination != null
        ? i18n.metroFirstTrainTowards(nextPrefix, status.firstDestination!)
        : nextPrefix;

    return Container(
      padding: const EdgeInsets.all(AppTheme.space14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: AppTextStyles.bodyLarge.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: AppTextStyles.bodySmall.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
          if (status.firstTrain != null) ...[
            const SizedBox(height: AppTheme.space10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  status.firstTrain!,
                  style: AppTextStyles.memo.copyWith(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: AppTheme.space8),
                Text(
                  nextLabel,
                  style: AppTextStyles.bodySmall.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Compact inline notice shown above the arrivals list (or the empty state)
/// when the live ETA stream has failed — small on purpose, since whatever
/// arrivals are still displayed underneath it are last-known, not blanked.
class _MetroLiveErrorNotice extends StatelessWidget {
  const _MetroLiveErrorNotice({required this.error});

  final AppError error;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.cloud_off_rounded, size: 16, color: cs.error),
        const SizedBox(width: AppTheme.space6),
        Expanded(
          child: Text(
            error.titleOf(AppI18n.of(context)),
            style: AppTextStyles.bodySmall.copyWith(color: cs.error),
          ),
        ),
      ],
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/grpc/resilient_stream.dart';
import 'package:wheres_the_bus/data/models/arrival_display.dart';
import 'package:wheres_the_bus/data/models/bus_models.dart';
import 'package:wheres_the_bus/data/models/search_models.dart';
import 'package:wheres_the_bus/data/repositories/bus_repository.dart';
import 'package:wheres_the_bus/features/search/genui/model/genui_node.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/eta_list_tile.dart';

const int _kLiveEtaCards = 2;

/// Arrivals shown inside one route card. The full board is one tap away.
const int _kArrivalsPerCard = 3;

/// Opens the live arrival board for a stop. Defaults to the real stream;
/// injectable so the card's number path can be tested without gRPC.
typedef StopEtaSource = Stream<List<BusStopArrival>> Function(SearchResult);

Stream<List<BusStopArrival>> _defaultEtaSource(SearchResult stop) =>
    resilientStream(
      () => BusRepository.instance.stationEta(stop.city ?? '', stop.uid),
    );

class GenUiRenderer extends StatelessWidget {
  const GenUiRenderer({
    required this.nodes,
    required this.refs,
    required this.onAsk,
    required this.onOpen,
    this.etaSource = _defaultEtaSource,
    super.key,
  });

  final List<GenUiNode> nodes;
  final Map<String, SearchResult> refs;
  final StopEtaSource etaSource;

  /// Re-asks with a new query, in place. A chip used to close the sheet and
  /// downgrade the answer into a keyword search; now it just asks again.
  final ValueChanged<String> onAsk;

  final ValueChanged<SearchResult> onOpen;

  SearchResult? _refOf(String? refUid) => refUid == null ? null : refs[refUid];

  @override
  Widget build(BuildContext context) {
    // Assigned in document order so the live boards land on the stops the
    // model put first, which is the one it considered most relevant.
    var liveBudget = _kLiveEtaCards;
    final children = <Widget>[];
    for (final (i, node) in nodes.indexed) {
      final ref = switch (node) {
        GenUiRoute(:final refUid) => _refOf(refUid),
        GenUiChip(:final refUid) => _refOf(refUid),
        _ => null,
      };
      var live = false;
      if (node is GenUiRoute && ref?.type == SearchResultType.busStation) {
        live = liveBudget > 0;
        if (live) liveBudget--;
      }
      children.add(
        _StaggerIn(
          index: i,
          child: Padding(
            padding: const EdgeInsets.only(bottom: AppTheme.space12),
            child: _node(context, node, ref, live: live),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _node(
    BuildContext context,
    GenUiNode node,
    SearchResult? ref, {
    required bool live,
  }) {
    final cs = Theme.of(context).colorScheme;
    switch (node) {
      case GenUiHeading():
        return Text(
          node.text,
          style: AppTextStyles.bodySmall.copyWith(
            fontWeight: FontWeight.w600,
            color: cs.onSurfaceVariant,
          ),
        );
      case GenUiText():
        return Text(
          node.text,
          style: AppTextStyles.bodyRegular.copyWith(color: cs.onSurface),
        );
      case GenUiRoute():
        final card = _RouteCard(
          node: node,
          ref: ref,
          live: live,
          etaSource: etaSource,
        );
        if (ref == null) return card;
        return Pressable(
          onTap: () => onOpen(ref),
          // The real stop name, not the model's title: the label a screen
          // reader announces has to match the page the tap opens.
          semanticLabel: ref.name,
          child: card,
        );
      case GenUiStep():
        return _StepRow(node: node);
      case GenUiChip():
        return Pressable(
          onTap: () => ref != null ? onOpen(ref) : onAsk(node.query),
          semanticLabel: ref?.name ?? node.label,
          minTapSize: 44,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.space14,
              vertical: 9,
            ),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppTheme.radiusStadium),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  ref != null
                      ? Icons.arrow_outward_rounded
                      : Icons.search_rounded,
                  size: 15,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: AppTheme.space6),
                Text(
                  node.label,
                  style: AppTextStyles.bodySmall.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
        );
      case GenUiDivider():
        return Divider(height: 1, thickness: 0.5, color: cs.outlineVariant);
    }
  }
}

class _RouteCard extends StatelessWidget {
  const _RouteCard({
    required this.node,
    required this.ref,
    required this.live,
    required this.etaSource,
  });

  final GenUiRoute node;
  final SearchResult? ref;

  /// Whether this card may open a live ETA stream (see [_kLiveEtaCards]).
  final bool live;

  final StopEtaSource etaSource;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final stop = live ? ref : null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.space14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusCard),
        boxShadow: AppShadows.cardFor(cs.brightness),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  // The resolved result's own name wins over the model's
                  // title: it is the thing the tap actually opens.
                  ref?.name ?? node.title,
                  style: AppTextStyles.bodyLarge.copyWith(
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
              ),
              if (ref != null)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
            ],
          ),
          if (ref?.subtitle.isNotEmpty ?? false) ...[
            const SizedBox(height: AppTheme.space2),
            Text(
              ref!.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodySmall.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
          if (node.badges.isNotEmpty) ...[
            const SizedBox(height: AppTheme.space8),
            Wrap(
              spacing: AppTheme.space6,
              runSpacing: AppTheme.space6,
              children: [
                for (final badge in node.badges) _Badge(text: badge),
              ],
            ),
          ],
          if (stop != null) _StopArrivals(stop: stop, etaSource: etaSource),
        ],
      ),
    );
  }
}

/// A route label from the model. Neutral, never an ink fill: the Achromatic
/// Rule reserves solid ink for the primary action, and a row of ink badges is
/// the brightest block on a dark screen (the Ink Inversion Rule).
class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

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
      child: Text(
        text,
        style: AppTextStyles.bodySmall.copyWith(
          fontWeight: FontWeight.w700,
          color: cs.onSurface,
        ),
      ),
    );
  }
}

class _StopArrivals extends StatefulWidget {
  const _StopArrivals({required this.stop, required this.etaSource});

  final SearchResult stop;
  final StopEtaSource etaSource;

  @override
  State<_StopArrivals> createState() => _StopArrivalsState();
}

class _StopArrivalsState extends State<_StopArrivals> {
  StreamSubscription<List<BusStopArrival>>? _sub;
  List<BusStopArrival> _arrivals = const [];

  @override
  void initState() {
    super.initState();
    _sub = widget.etaSource(widget.stop).listen(
      (arrivals) {
        if (mounted) setState(() => _arrivals = arrivals);
      },
      // A stop with no board is rendered as a stop with no board. There is
      // nothing honest to say here that the card doesn't already say.
      onError: (Object _) {},
    );
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_arrivals.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final i18n = AppI18n.of(context);
    final displays =
        _arrivals.map((a) => ArrivalDisplay.fromBusStop(i18n, a)).toList()
          ..sort((a, b) => a.rank.compareTo(b.rank));
    final shown = displays.take(_kArrivalsPerCard).toList();

    return Padding(
      padding: const EdgeInsets.only(top: AppTheme.space10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(height: 1, thickness: 0.5, color: cs.outlineVariant),
          const SizedBox(height: AppTheme.space8),
          for (final (i, d) in shown.indexed)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : AppTheme.space6),
              child: _ArrivalRow(
                display: d,
                // At most one per card, and only when it really is imminent.
                highlighted: i == 0 && d.isComingSoon,
              ),
            ),
        ],
      ),
    );
  }
}

class _ArrivalRow extends StatelessWidget {
  const _ArrivalRow({required this.display, required this.highlighted});

  final ArrivalDisplay display;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Both variants carry the same inset, so the highlight can appear and
    // disappear as the board updates without the rows shifting sideways.
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space8,
        vertical: AppTheme.space4,
      ),
      // Static highlight: background only, never a pulse.
      decoration: highlighted
          ? BoxDecoration(
              color: AppTheme.surfaceHighlight(cs.brightness),
              borderRadius: BorderRadius.circular(AppTheme.radiusCard),
            )
          : null,
      child: EtaListTile.fromDisplay(display, bare: true),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.node});
  final GenUiStep node;

  IconData get _icon => switch (node.kind) {
    GenUiStepKind.board => Icons.login_rounded,
    GenUiStepKind.ride => Icons.directions_transit_rounded,
    GenUiStepKind.walk => Icons.directions_walk_rounded,
    GenUiStepKind.alight => Icons.logout_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(_icon, size: 18, color: cs.onSurfaceVariant),
        const SizedBox(width: AppTheme.space10),
        Expanded(
          child: Text(
            node.text,
            style: AppTextStyles.bodyRegular.copyWith(color: cs.onSurface),
          ),
        ),
      ],
    );
  }
}

class _StaggerIn extends StatelessWidget {
  const _StaggerIn({required this.index, required this.child});
  final int index;
  final Widget child;

  static const _step = Duration(milliseconds: 30);

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return child;
    final delay = _step * index;
    final total = AppMotion.medium + delay;
    final start = delay.inMilliseconds / total.inMilliseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1, curve: AppMotion.easeOut),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 4 * (1 - t)),
          child: child,
        ),
      ),
    );
  }
}

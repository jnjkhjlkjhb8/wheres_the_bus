import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/data/models/plan_models.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_bloc.dart';
import 'package:wheres_the_bus/features/go/bloc/plan_state.dart';
import 'package:wheres_the_bus/features/go/widgets/route_option_card.dart';
import 'package:wheres_the_bus/features/go/widgets/transit_visuals.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

class NavMiniBar extends StatelessWidget {
  const NavMiniBar({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PlanBloc, PlanState>(
      buildWhen: (p, c) =>
          p.activeLegIndex != c.activeLegIndex ||
          p.selectedRouteIndex != c.selectedRouteIndex,
      builder: (context, state) {
        final route = _route(state);
        final activeLeg = state.activeLegIndex;
        if (route == null || activeLeg == null) {
          return const SizedBox.shrink();
        }
        if (activeLeg < 0 || activeLeg >= route.sections.length) {
          return const SizedBox.shrink();
        }
        return _MiniBar(route: route, activeLeg: activeLeg);
      },
    );
  }

  PlanRoute? _route(PlanState state) {
    final routes = state.result?.routes;
    if (routes == null || routes.isEmpty) return null;
    final i = state.selectedRouteIndex ?? 0;
    return i >= 0 && i < routes.length ? routes[i] : routes.first;
  }
}

class _MiniBar extends StatelessWidget {
  const _MiniBar({required this.route, required this.activeLeg});

  final PlanRoute route;
  final int activeLeg;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final section = route.sections[activeLeg];
    final color = isWalk(section)
        ? cs.onSurfaceVariant
        : transitColor(section.transport, cs);
    final dest = route.sections.last.arrival.name;
    final arrival = formatClock(route.endTime);
    final title = isWalk(section)
        ? AppI18n.of(context).walkToward(section.arrival.name)
        : AppI18n.of(
            context,
          ).rideVehicle(sectionLabel(AppI18n.of(context), section));

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.space16,
          0,
          AppTheme.space16,
          AppTheme.space12,
        ),
        child: Pressable(
          onTap: () {
            if (GoRouterState.of(context).uri.path == AppRoutes.go) return;
            unawaited(context.push(AppRoutes.go));
          },
          semanticLabel: AppI18n.of(context).navBackSemantics(dest),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.space12,
              vertical: AppTheme.space10,
            ),
            decoration: AppTheme.floatingControl(
              cs,
              borderRadius: BorderRadius.circular(AppTheme.radiusCard),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(AppTheme.radiusChip),
                  ),
                  child: Icon(
                    transitIcon(section.transport.mode),
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: AppTheme.space10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodyRegular.copyWith(
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        ),
                      ),
                      Text(
                        AppI18n.of(context).towards(dest),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodySmall.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppTheme.space10),
                if (arrival.isNotEmpty)
                  Text(
                    arrival,
                    style: AppTextStyles.timeValue(
                      size: 16,
                      weight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                const SizedBox(width: AppTheme.space4),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: cs.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

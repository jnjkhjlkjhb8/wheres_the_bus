part of '../view/bus_route_screen.dart';

class _FloatingAppBar extends StatelessWidget {
  const _FloatingAppBar({
    required this.subRouteUid,
    required this.routeName,
    required this.dirName,
    required this.direction,
  });
  final String subRouteUid;
  final String routeName;
  final String dirName;
  final int direction;

  @override
  Widget build(BuildContext context) {
    return FloatingAppBar(
      // maybePop rather than the button's default pop: it asks the page's
      // PopScope first, so tapping back collapses a raised sheet exactly like
      // the system back gesture does.
      leading: AppBarBackButton(
        floating: true,
        onTap: () => unawaited(context.maybePopOrHome()),
      ),
      // The name arrives with the route; until then the pill is bones rather
      // than a blank plate.
      middle: Skeletonizer(
        enabled: routeName.isEmpty,
        child: _RoutePill(
          routeName: routeName.isEmpty ? BoneMock.chars(3, '囗') : routeName,
          dirName: routeName.isEmpty ? BoneMock.chars(6, '囗') : dirName,
          direction: direction,
        ),
      ),
      trailing: AppBarCircleButton(
        semanticLabel: AppI18n.of(context).commonFavorite,
        child: BookmarkButton(
          routeType: 'bus',
          routeKey: subRouteUid,
          routeLabel: routeName,
          onPlate: true,
        ),
      ),
    );
  }
}

class _RoutePill extends StatelessWidget {
  const _RoutePill({
    required this.routeName,
    required this.dirName,
    required this.direction,
  });
  final String routeName;
  final String dirName;
  final int direction;

  Offset _transitionOffset(AnimationStatus status) {
    final incoming =
        status == AnimationStatus.forward ||
        status == AnimationStatus.completed;
    final sign = direction == 1 ? 1.0 : -1.0;
    return Offset(0, incoming ? sign : -sign);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space16,
        vertical: AppTheme.space10,
      ),
      decoration: BoxDecoration(
        color: cs.brightness == Brightness.light
            ? Colors.white
            : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppTheme.radiusCard),
        boxShadow: AppShadows.floating,
      ),
      child: Row(
        spacing: AppTheme.space6,
        children: [
          Text(
            routeName,
            style: AppTextStyles.bodyLarge.copyWith(
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: AppMotion.short,
              switchInCurve: AppMotion.easeOut,
              switchOutCurve: AppMotion.easeOut,
              transitionBuilder: (child, animation) {
                final beginOffset = _transitionOffset(animation.status);

                return ClipRect(
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: beginOffset,
                      end: Offset.zero,
                    ).animate(animation),
                    child: FadeTransition(
                      opacity: animation,
                      child: child,
                    ),
                  ),
                );
              },
              layoutBuilder: (currentChild, previousChildren) {
                return Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    ...previousChildren,
                    ?currentChild,
                  ],
                );
              },
              child: Text(
                dirName,
                key: ValueKey(dirName),
                style: AppTextStyles.bodyRegular.copyWith(
                  color: cs.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

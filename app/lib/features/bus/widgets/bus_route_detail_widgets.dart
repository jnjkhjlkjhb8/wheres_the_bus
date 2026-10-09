part of '../view/bus_route_screen.dart';

class _RouteDetailTab extends StatelessWidget {
  const _RouteDetailTab({required this.state});
  final BusRouteState state;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final departures = _departuresFor(state);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppTheme.space16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppTheme.space24,
        children: [
          _NextDepartures(cs: cs, departures: departures),
          _RouteMeta(cs: cs, state: state),
          _Operators(cs: cs, operators: state.route?.operators ?? const []),
          _Fares(cs: cs, fare: state.fare),
          _Timetable(cs: cs, headsign: _headsignFor(state), state: state),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {required this.cs});
  final String text;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: AppTextStyles.heading2.copyWith(color: cs.onSurfaceVariant),
  );
}

class _EmptyDetailText extends StatelessWidget {
  const _EmptyDetailText(this.text, {required this.cs});
  final String text;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return AppCard.filled(
      child: Text(
        text,
        style: AppTextStyles.bodyRegular.copyWith(
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _NextDepartures extends StatelessWidget {
  const _NextDepartures({required this.cs, required this.departures});
  final ColorScheme cs;
  final List<_DepartureInfo> departures;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AppTheme.space12,
      children: [
        _SectionLabel(AppI18n.of(context).busNextDepartures, cs: cs),
        if (departures.isEmpty)
          _EmptyDetailText(AppI18n.of(context).busNoDepartures, cs: cs)
        else
          // Edge fade signals the strip is scrollable instead of cutting the
          // last pill off mid-glyph with no affordance. The gradient is a
          // mask (dstIn), not UI color, so it sits outside the token rule.
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [
                Colors.transparent,
                Colors.black,
                Colors.black,
                Colors.transparent,
              ],
              stops: [0, 0.03, 0.94, 1],
            ).createShader(bounds),
            blendMode: BlendMode.dstIn,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                spacing: AppTheme.space8,
                children: [
                  for (final item in departures)
                    _DeparturePill(
                      time: item.time,
                      isNext: item.isNext,
                      cs: cs,
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _DeparturePill extends StatelessWidget {
  const _DeparturePill({
    required this.time,
    required this.isNext,
    required this.cs,
  });
  final String time;
  final bool isNext;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space14,
        vertical: AppTheme.space10,
      ),
      decoration: BoxDecoration(
        color: isNext ? cs.primary : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusButton),
      ),
      child: Text(
        time,
        style: AppTextStyles.bodyRegular.copyWith(
          fontFeatures: _tnum,
          fontWeight: isNext ? FontWeight.w600 : FontWeight.w400,
          color: isNext ? cs.onPrimary : cs.onSurface,
        ),
      ),
    );
  }
}

class _RouteMeta extends StatelessWidget {
  const _RouteMeta({required this.cs, required this.state});
  final ColorScheme cs;
  final BusRouteState state;

  @override
  Widget build(BuildContext context) {
    final route = state.route;
    final stops = state.currentStops;
    final origin = route?.departureStopName.isNotEmpty == true
        ? route!.departureStopName
        : (stops.isEmpty ? '-' : stops.first.stopName);
    final destination = route?.destinationStopName.isNotEmpty == true
        ? route!.destinationStopName
        : (stops.isEmpty ? '-' : stops.last.stopName);
    // route.city is a TDX county code (e.g. "Taoyuan"), and it names where
    // the route operates, not a regulator — map it to its Chinese name
    // rather than label it 主管機關 and leak the English identifier.
    final city = route?.city.isNotEmpty == true
        ? _dtCityLabel(AppI18n.of(context), route!.city)
        : '-';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: AppTheme.space4,
            children: [
              _SectionLabel(AppI18n.of(context).busOperatingCities, cs: cs),
              Text(city, style: AppTextStyles.bodyLarge),
            ],
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: AppTheme.space4,
            children: [
              _SectionLabel(AppI18n.of(context).busEndpoints, cs: cs),
              _originDestinationLine(
                context,
                origin: origin,
                destination: destination,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _originDestinationLine(
    BuildContext context, {
    required String origin,
    required String destination,
  }) {
    const style = AppTextStyles.bodyLarge;
    const arrow = '→';
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        double widthOf(String text) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            textScaler: scaler,
          )..layout();
          return painter.width;
        }

        final needed =
            widthOf(origin) + widthOf(arrow) + widthOf(destination) + 8;
        final fits =
            constraints.maxWidth.isFinite && needed <= constraints.maxWidth;
        if (fits) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.end,
            spacing: AppTheme.space4,
            children: [
              Flexible(
                child: Text(
                  origin,
                  style: style,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Text(arrow, style: style),
              Flexible(
                child: Text(
                  destination,
                  style: style,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          spacing: AppTheme.space2,
          children: [
            Text(origin, style: style, textAlign: TextAlign.end),
            const Text('↓', style: style),
            Text(destination, style: style, textAlign: TextAlign.end),
          ],
        );
      },
    );
  }
}

class _Operators extends StatelessWidget {
  const _Operators({required this.cs, required this.operators});
  final ColorScheme cs;
  final List<BusOperatorInfo> operators;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AppTheme.space12,
      children: [
        _SectionLabel(AppI18n.of(context).busOperators, cs: cs),
        if (operators.isEmpty)
          _EmptyDetailText(AppI18n.of(context).busNoOperators, cs: cs)
        else
          AppCard.outlined(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final (i, op) in operators.indexed) ...[
                  if (i > 0) const DividerLine(),
                  _OperatorRow(op: op, cs: cs),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _OperatorRow extends StatelessWidget {
  const _OperatorRow({required this.op, required this.cs});
  final BusOperatorInfo op;
  final ColorScheme cs;

  // TDX operator phones arrive as free text (e.g. "(02)2999-2020"); strip
  // formatting so the tel: URI dials.
  static Future<void> _dial(String phone) async {
    final digits = phone.replaceAll(RegExp('[^0-9+]'), '');
    if (digits.isEmpty) return;
    await launchUrl(Uri(scheme: 'tel', path: digits));
  }

  static Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final inApp = uri.scheme == 'https' || uri.scheme == 'http';
    if (inApp) {
      try {
        await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
        return;
      } on Object catch (_) {
        // Fall through to the external handler below.
      }
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space16,
        vertical: AppTheme.space14,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 3,
              children: [
                Text(
                  op.name.isEmpty ? '-' : op.name,
                  style: AppTextStyles.bodyLarge.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                if (op.phone.isNotEmpty)
                  Text(
                    op.phone,
                    style: AppTextStyles.bodySmall.copyWith(
                      fontFeatures: _tnum,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (op.phone.isNotEmpty)
            _OperatorIconButton(
              icon: Icons.phone_outlined,
              label: AppI18n.of(context).callOperator(op.name),
              cs: cs,
              onTap: () => _dial(op.phone),
            ),
          if (op.url.isNotEmpty) ...[
            const SizedBox(width: AppTheme.space8),
            _OperatorIconButton(
              icon: Icons.language_outlined,
              label: AppI18n.of(context).operatorWebsite(op.name),
              cs: cs,
              onTap: () => _open(op.url),
            ),
          ],
        ],
      ),
    );
  }
}

class _OperatorIconButton extends StatelessWidget {
  const _OperatorIconButton({
    required this.icon,
    required this.label,
    required this.cs,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final ColorScheme cs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      semanticLabel: label,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(AppTheme.radiusButton),
        ),
        child: Icon(icon, size: 18, color: cs.onSurface),
      ),
    );
  }
}

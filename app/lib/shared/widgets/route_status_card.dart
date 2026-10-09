import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';

/// Route progress card with station markers and prominent times.
class RouteStatusCard extends StatelessWidget {
  const RouteStatusCard({
    required this.origin,
    required this.destination,
    required this.departureTime,
    required this.arrivalTime,
    this.lineColor,
    super.key,
  });

  final String origin;
  final String destination;
  final String departureTime;
  final String arrivalTime;
  final Color? lineColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = lineColor ?? theme.colorScheme.primary;
    return Container(
      height: 80,
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.space12,
        vertical: AppTheme.space10,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radiusCard),
        boxShadow: AppShadows.cardFor(theme.colorScheme.brightness),
      ),
      child: Row(
        children: [
          _MarkerLine(color: color),
          const SizedBox(width: AppTheme.space10),
          Expanded(
            child: _StationLabels(origin: origin, destination: destination),
          ),
          _RouteTimes(departure: departureTime, arrival: arrivalTime),
        ],
      ),
    );
  }
}

class _MarkerLine extends StatelessWidget {
  const _MarkerLine({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 12,
    child: Column(
      children: [
        _dot(),
        Expanded(child: Container(width: 2, color: color)),
        _dot(),
      ],
    ),
  );

  Widget _dot() => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(
      color: ThemeData.estimateBrightnessForColor(color) == Brightness.dark
          ? Colors.white
          : Colors.black,
      shape: BoxShape.circle,
      border: Border.all(color: color, width: 3),
    ),
  );
}

class _StationLabels extends StatelessWidget {
  const _StationLabels({required this.origin, required this.destination});
  final String origin;
  final String destination;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _FittedLabel(text: origin, style: Theme.of(context).textTheme.bodyMedium),
      _FittedLabel(
        text: destination,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    ],
  );
}

class _RouteTimes extends StatelessWidget {
  const _RouteTimes({required this.departure, required this.arrival});
  final String departure;
  final String arrival;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      _FittedLabel(
        text: departure,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 18),
      ),
      _FittedLabel(
        text: arrival,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 18),
      ),
    ],
  );
}

class _FittedLabel extends StatelessWidget {
  const _FittedLabel({required this.text, required this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Flexible(
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    ),
  );
}

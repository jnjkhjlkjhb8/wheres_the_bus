part of '../home_screen.dart';

const int _kLabelAllUpTo = 3;

const double _kMemberBoundsPadding = 120;

const double _kRecentreThresholdFrac = 0.22;

/// Metres per degree of latitude. A station group spans ~100 m, so the
/// spherical correction is far below a pixel.
const double _kMetresPerDegree = 111320;

enum _SpreadPhase {
  /// No group open.
  idle,

  /// Group tapped, poles still being fetched. Its own pin stands in — the wait
  /// is a network round trip long and the spot the user tapped stays occupied.
  holding,

  /// Poles on the map.
  open,
}

typedef _MemberSpread = ({
  LatLng origin,
  List<BusStationMember> members,
  Map<String, String> labels,
  String? selectedUid,
});

/// How one pole is drawn, resolved once per spread.
typedef _SpreadPart = ({
  BusStationMember member,
  String label,
  bool labelled,
  bool selected,
  bool flip,
});

Offset _projectToScreen({
  required LatLng point,
  required LatLng center,
  required double zoom,
  required Size viewport,
  required double bottomPadding,
}) {
  final mpp = metersPerPixel(center.latitude, zoom);
  final cosLat = math.cos(center.latitude * math.pi / 180);
  final dx =
      (point.longitude - center.longitude) * _kMetresPerDegree * cosLat / mpp;
  final dy = -(point.latitude - center.latitude) * _kMetresPerDegree / mpp;
  return Offset(
    viewport.width / 2 + dx,
    (viewport.height - bottomPadding) / 2 + dy,
  );
}

extension _HomeScreenMemberCapsules on _HomeScreenState {
  /// Resolves each pole's part and caches it for the run.
  void _resolveSpreadParts(_MemberSpread spread) {
    final labelAll = spread.members.length <= _kLabelAllUpTo;
    _spreadParts = [
      for (final m in spread.members)
        _spreadPart(m, spread, labelAll: labelAll),
    ];
  }

  _SpreadPart _spreadPart(
    BusStationMember member,
    _MemberSpread spread, {
    required bool labelAll,
  }) {
    final selected = member.stationUid == spread.selectedUid;
    final label = spread.labels[member.stationUid] ?? member.stationName;
    final named = label.startsWith(kMemberDestinationPrefix);
    return (
      member: member,
      label: label,
      labelled: named ? labelAll || selected : selected,
      selected: selected,
      flip: member.lon < spread.origin.longitude,
    );
  }

  /// Publishes the poles as markers, replacing whatever the group set held —
  /// the holding pin on the way in, an older selection on a refresh.
  Future<void> _publishMemberMarkers() async {
    final revision = ++_memberRevision;
    if (_spreadParts.isEmpty) {
      _memberMarkers.value = const {};
      return;
    }
    final built = <Marker>[];
    for (final part in _spreadParts) {
      final capsule = part.labelled
          ? await MapMarkers.stationCapsule(
              asset: 'assets/marker/Bus.svg',
              label: part.label,
              selected: part.selected,
              flip: part.flip,
            )
          : (
              icon: await MapMarkers.svgAsset(
                'assets/marker/Bus.svg',
                size: _kIconMarkerSize,
              ),
              anchor: const Offset(0.5, 0.5),
            );
      built.add(
        Marker(
          markerId: MarkerId('member:${part.member.stationUid}'),
          position: LatLng(part.member.lat, part.member.lon),
          icon: capsule.icon,
          anchor: capsule.anchor,
          zIndexInt: part.selected ? 1 : 0,
          onTap: () =>
              _selectMember(part.selected ? null : part.member.stationUid),
        ),
      );
    }
    if (!mounted || revision != _memberRevision) return;
    _memberMarkers.value = built.toSet();
  }

  /// Stand-in for the tapped group while its poles are being fetched. It moves
  /// out of the nearby set and into this one the moment the group is opened,
  /// so nothing blinks where the user just tapped.
  Future<void> _holdGroupPin(NearStationViewModel station) async {
    final revision = _memberRevision;
    final icon = await _markerIcon(station, _markerStyle(_zoom));
    if (!mounted ||
        revision != _memberRevision ||
        _spreadPhase.value != _SpreadPhase.holding) {
      return;
    }
    _memberMarkers.value = {
      Marker(
        markerId: MarkerId('${station.type.name}:${station.stationId}'),
        position: LatLng(station.lat, station.lon),
        icon: icon,
        anchor: const Offset(0.5, 0.5),
      ),
    };
  }
}

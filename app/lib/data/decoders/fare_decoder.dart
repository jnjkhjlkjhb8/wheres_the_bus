import 'dart:convert';
import 'dart:math' as math;

import 'package:wheres_the_bus/data/models/bus_route_detail.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

Set<int> decodeBufferSequences(BusFareInfo? fare) {
  if (fare == null) return const {};
  return {
    for (final section in _decodeList(fare.sectionFaresJson))
      ..._bufferSequences(section),
  };
}

Iterable<int> _bufferSequences(Object? section) sync* {
  if (section is! Map) return;
  yield* _bufferZoneSequences(section['BufferZones']);
}

Iterable<int> _bufferZoneSequences(Object? zones) sync* {
  if (zones is! List) return;
  for (final zone in zones) {
    yield* _bufferSequence(zone);
  }
}

Iterable<int> _bufferSequence(Object? zone) {
  if (zone is! Map) return const [];
  final sequence = zone['StopSequence'];
  return sequence is num ? [sequence.toInt()] : const [];
}

/// A price row within a fare group: fare-class label + `NT$15`, plus the TDX
/// FareClass code it came from so a row can be matched to a rider's ticket
/// type (see [pickFareRow]).
typedef FareRow = ({String label, String price, int fareClass});

/// A fare group. `segment` labels the origin→destination stage / OD segment
/// (公路客運) or 第N段 when a route has multiple sections; it is null for a
/// single flat section (typical city bus), where the rows stand alone.
typedef FareGroup = ({String? segment, List<FareRow> rows});

List<FareGroup> decodeFareTable(AppI18n i18n, BusFareInfo? fare) {
  if (fare == null) return const [];
  final groups = <FareGroup>[];
  _addSectionGroups(i18n, fare.sectionFaresJson, groups);
  _addSegmentGroups(i18n, fare.stageFaresJson, groups);
  _addSegmentGroups(i18n, fare.odFaresJson, groups);
  return groups;
}

/// All destinations reachable from one boarding stop, each carrying its own
/// fare rows. `destination` is the arrival stop name.
typedef OdDestination = ({String destination, List<FareRow> rows});

typedef OdOrigin = ({String origin, List<OdDestination> destinations});

List<OdOrigin> decodeOdFares(AppI18n i18n, BusFareInfo? fare) {
  if (fare == null) return const [];
  final byOrigin = <String, List<OdDestination>>{};
  final order = <String>[];
  for (final payload in [fare.stageFaresJson, fare.odFaresJson]) {
    _collectOdFares(i18n, payload, byOrigin, order);
  }
  return [for (final o in order) (origin: o, destinations: byOrigin[o]!)];
}

void _collectOdFares(
  AppI18n i18n,
  List<int> payload,
  Map<String, List<OdDestination>> byOrigin,
  List<String> order,
) {
  for (final entry in _decodeList(payload)) {
    final decoded = _odFareEntry(i18n, entry);
    if (decoded == null) continue;
    byOrigin
        .putIfAbsent(decoded.origin, () {
          order.add(decoded.origin);
          return [];
        })
        .add(decoded.destination);
  }
}

({String origin, OdDestination destination})? _odFareEntry(
  AppI18n i18n,
  Object? entry,
) {
  if (entry is! Map) return null;
  final rows = _fareRows(i18n, entry['Fares']);
  if (rows.isEmpty) return null;
  return _namedOdFareEntry(entry, rows);
}

({String origin, OdDestination destination})? _namedOdFareEntry(
  Map<Object?, Object?> entry,
  List<FareRow> rows,
) {
  final origin = _stopName(entry['OriginStage'] ?? entry['OriginStop']);
  final destination = _stopName(
    entry['DestinationStage'] ?? entry['DestinationStop'],
  );
  if (origin == null || destination == null) return null;
  return (origin: origin, destination: (destination: destination, rows: rows));
}

({FareRow row, FareType matched})? pickFareRow(
  List<FareRow> rows,
  FareType type,
) {
  for (final fareClass in type.busFareClasses) {
    final row = _fareRowForClass(rows, fareClass);
    if (row != null) {
      return (row: row, matched: type.matchedWhen(isFullFare: fareClass == 1));
    }
  }
  // A route whose classes are all unmapped codes still has a price to show;
  // quoting its first row beats quoting nothing.
  return _fallbackFareRow(rows, type);
}

FareRow? _fareRowForClass(List<FareRow> rows, int fareClass) {
  for (final row in rows) {
    if (row.fareClass == fareClass) return row;
  }
  return null;
}

({FareRow row, FareType matched})? _fallbackFareRow(
  List<FareRow> rows,
  FareType type,
) => rows.isEmpty ? null : (row: rows.first, matched: type);

({int min, int max})? odFareRange(List<OdOrigin> origins, FareType type) {
  var min = -1;
  var max = -1;
  for (final value in origins.expand((origin) => _farePrices(origin, type))) {
    min = _minimumFare(min, value);
    max = math.max(max, value);
  }
  return _fareRangeOrNull(min, max);
}

int _minimumFare(int current, int next) =>
    current < 0 ? next : math.min(current, next);
({int min, int max})? _fareRangeOrNull(int min, int max) =>
    min < 0 ? null : (min: min, max: max);

Iterable<int> _farePrices(OdOrigin origin, FareType type) sync* {
  for (final dest in origin.destinations) {
    final picked = pickFareRow(dest.rows, type);
    if (picked == null) continue;
    final n = int.tryParse(picked.row.price.replaceAll(RegExp('[^0-9]'), ''));
    if (n != null) yield n;
  }
}

void _addSectionGroups(AppI18n i18n, List<int> payload, List<FareGroup> out) {
  final sections = _decodeList(
    payload,
  ).whereType<Map<Object?, Object?>>().toList();
  for (final (index, section) in sections.indexed) {
    final group = _sectionGroup(i18n, section, index, sections.length > 1);
    if (group != null) out.add(group);
  }
}

FareGroup? _sectionGroup(
  AppI18n i18n,
  Map<Object?, Object?> section,
  int index,
  bool numbered,
) {
  final rows = _fareRows(i18n, section['Fares']);
  if (rows.isEmpty) return null;
  return (
    segment: numbered ? i18n.fareSectionNumbered(index + 1) : null,
    rows: rows,
  );
}

void _addSegmentGroups(AppI18n i18n, List<int> payload, List<FareGroup> out) {
  for (final entry in _decodeList(payload)) {
    final group = _segmentGroup(i18n, entry);
    if (group != null) out.add(group);
  }
}

FareGroup? _segmentGroup(AppI18n i18n, Object? entry) {
  if (entry is! Map) return null;
  final rows = _fareRows(i18n, entry['Fares']);
  if (rows.isEmpty) return null;
  return (segment: _segmentLabel(entry), rows: rows);
}

List<Object?> _decodeList(List<int> payload) {
  if (payload.isEmpty) return const [];
  try {
    final parsed = jsonDecode(utf8.decode(payload));
    return parsed is List ? parsed : const [];
  } on Object catch (_) {
    return const [];
  }
}

// Origin → destination for a stage/OD entry. Stage/OD descriptors carry a
// StopName that TDX serialises as a plain string (stage sample) or a localized
// {Zh_tw, En} object; both are handled. Null when either endpoint is missing.
String? _segmentLabel(Map<Object?, Object?> entry) {
  final o = _stopName(entry['OriginStage'] ?? entry['OriginStop']);
  final d = _stopName(entry['DestinationStage'] ?? entry['DestinationStop']);
  if (o == null || d == null) return null;
  return '$o → $d';
}

String? _stopName(Object? stop) {
  if (stop is! Map) return null;
  final name = stop['StopName'];
  return _fareName(name) ?? _localizedStopName(name);
}

String? _localizedStopName(Object? name) =>
    name is Map ? _fareName(name['Zh_tw']) : null;

typedef _FareVariant = ({String? name, int ticket, int price});

List<FareRow> _fareRows(AppI18n i18n, Object? faresRaw) {
  final byClass = _groupFares(faresRaw);
  return [
    for (final cls in _fareClassOrder(byClass.keys))
      ..._classRows(i18n, cls, byClass[cls]!),
  ];
}

Map<int, List<_FareVariant>> _groupFares(Object? faresRaw) {
  if (faresRaw is! List) return const {};
  final byClass = <int, List<_FareVariant>>{};
  for (final raw in faresRaw) {
    final entry = _fareEntry(raw);
    if (entry == null) continue;
    byClass.putIfAbsent(entry.fareClass, () => []).add(entry.variant);
  }
  return byClass;
}

({int fareClass, _FareVariant variant})? _fareEntry(Object? raw) {
  if (raw is! Map) return null;
  return _mappedFareEntry(raw);
}

({int fareClass, _FareVariant variant})? _mappedFareEntry(
  Map<Object?, Object?> raw,
) {
  final cls = raw['FareClass'];
  final price = _positiveFarePrice(raw['Price']);
  if (cls is! num || price == null) return null;
  return (
    fareClass: cls.toInt(),
    variant: (
      name: _fareName(raw['FareName']),
      ticket: _ticketType(raw['TicketType']),
      price: price.toInt(),
    ),
  );
}

num? _positiveFarePrice(Object? price) =>
    price is num && price > 0 ? price : null;
int _ticketType(Object? ticket) => ticket is num ? ticket.toInt() : 0;

String? _fareName(Object? name) =>
    name is String && name.isNotEmpty ? name : null;

Iterable<FareRow> _classRows(
  AppI18n i18n,
  int cls,
  List<_FareVariant> entries,
) sync* {
  final distinctPrices = {for (final e in entries) e.price};
  if (distinctPrices.length == 1) {
    yield (
      label: _fareClassLabel(i18n, cls),
      price: _money(entries.first.price),
      fareClass: cls,
    );
    return;
  }
  yield* _variantRows(i18n, cls, entries);
}

Iterable<FareRow> _variantRows(
  AppI18n i18n,
  int cls,
  List<_FareVariant> entries,
) sync* {
  // Prices split within the class (現金 vs 電子票證, or seat class): one row
  // per entry, deduped, labelled by TDX's FareName when it provides one.
  final seen = <String>{};
  for (final e in entries) {
    final label = _variantLabel(i18n, cls, e);
    if (seen.add('$label|${e.price}')) {
      yield (label: label, price: _money(e.price), fareClass: cls);
    }
  }
}

String _variantLabel(AppI18n i18n, int cls, _FareVariant entry) =>
    entry.name != null
    ? entry.name!.replaceAll('_', ' ')
    : '${_fareClassLabel(i18n, cls)}'
          '${entry.ticket == 3 ? i18n.fareSmartCard : ''}';

// TDX Bus FareClass enum (PTX). 1/10 confirmed against sample FareNames
// (全票/半票); the rest follow the documented enum. Unknown codes fall back to
// a numbered label rather than being dropped.
Map<int, String> _fareClassLabels(AppI18n i18n) => {
  1: i18n.fareClassFull,
  10: i18n.fareClassHalf,
  2: i18n.fareClassStudent,
  7: i18n.fareClassChild,
  3: i18n.fareClassSenior,
  4: i18n.fareClassDisabled,
  5: i18n.fareClassCompanion,
  6: i18n.fareClassGroup,
  9: i18n.fareClassOtherConcession,
};

// Headline classes (全票, 半票) first, then remaining known classes in map
// order, then any unmapped codes sorted — keeps the common rows on top.
List<int> _fareClassOrder(Iterable<int> classes) {
  const priority = [1, 10, 2, 7, 3, 4, 5, 6, 9];
  final present = classes.toSet();
  final known = [
    for (final c in priority)
      if (present.remove(c)) c,
  ];
  final unknown = present.toList()..sort();
  return [...known, ...unknown];
}

String _fareClassLabel(AppI18n i18n, int cls) =>
    _fareClassLabels(i18n)[cls] ?? i18n.fareClassUnknown(cls);

String _money(int price) => 'NT\$$price';

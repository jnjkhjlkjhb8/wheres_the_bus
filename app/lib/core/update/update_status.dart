import 'dart:io' show Platform;

import 'package:wheres_the_bus/core/firebase/remote_config.dart';

/// What the installed build's standing is against the published ones.
enum UpdateStatus {
  /// Nothing newer has been published (or the remote values are unusable).
  upToDate,

  /// A newer build exists. Optional: the rider is nudged, never stopped.
  available,

  /// Below `min_supported_version`. The app refuses to run.
  blocked,
}

UpdateStatus resolveUpdateStatus({
  required String current,
  required String minSupported,
  required String latest,
}) {
  if (isBelowVersion(current, minSupported)) return UpdateStatus.blocked;
  if (isBelowVersion(current, latest)) return UpdateStatus.available;
  return UpdateStatus.upToDate;
}

bool isBelowVersion(String current, String other) {
  final a = _segments(current);
  final b = _segments(other);
  if (a == null || b == null) return false;
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x < y;
  }
  return false;
}

List<int>? _segments(String v) {
  final core = v.split(RegExp('[+-]')).first.trim();
  final out = <int>[];
  for (final part in core.split('.')) {
    final n = int.tryParse(part);
    if (n == null) return null;
    out.add(n);
  }
  return out.isEmpty ? null : out;
}

/// Store hosts a `store_url_ios`/`store_url_android` Remote Config value is
/// allowed to point at.
const _allowedStoreHosts = {'apps.apple.com', 'play.google.com'};

bool isAllowedStoreUrl(Uri url) =>
    url.scheme == 'https' && _allowedStoreHosts.contains(url.host);

Uri? storeUrl({bool? isIOS}) {
  final raw = (isIOS ?? Platform.isIOS)
      ? AppConfig.getString('store_url_ios')
      : AppConfig.getString('store_url_android');
  final parsed = Uri.tryParse(raw);
  return parsed != null && isAllowedStoreUrl(parsed) ? parsed : null;
}

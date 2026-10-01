import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wheres_the_bus/core/firebase/firebase_call_options.dart';
import 'package:wheres_the_bus/core/firebase/install_identity.dart';
import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/data/generated/feedback.pbgrpc.dart' as pb;
import 'package:wheres_the_bus/data/models/feedback_models.dart';

/// Server-side ceiling on a diagnostics value. Values are truncated here rather
/// than sent long, so a device with an unusually verbose OS string still files
/// its report instead of being rejected for a field nobody reads closely.
const _diagnosticsFieldLimit = 128;

class FeedbackRepository {
  FeedbackRepository({
    pb.Feedback_ServiceClient? client,
    Future<PackageInfo> Function()? packageInfoLoader,
    String Function()? osVersionOf,
  }) : _client = client,
       _packageInfoLoader = packageInfoLoader ?? PackageInfo.fromPlatform,
       _osVersionOf = osVersionOf ?? _defaultOsVersion;

  static final FeedbackRepository instance = FeedbackRepository();

  final pb.Feedback_ServiceClient? _client;
  pb.Feedback_ServiceClient get _grpc =>
      _client ?? GrpcClient.instance.feedback;

  final Future<PackageInfo> Function() _packageInfoLoader;
  final String Function() _osVersionOf;

  static String _defaultOsVersion() => Platform.operatingSystemVersion;

  Future<FeedbackDiagnostics> collect({
    required String screen,
    required String locale,
  }) async {
    var appVersion = '';
    try {
      final info = await _packageInfoLoader();
      appVersion = '${info.version}+${info.buildNumber}';
    } on Object catch (_) {
      // Leave it blank rather than reporting a version that isn't running.
    }
    var osVersion = '';
    try {
      osVersion = _osVersionOf();
    } on Object catch (_) {
      // Unavailable on this platform; the report is still worth sending.
    }
    return FeedbackDiagnostics(
      appVersion: _field(appVersion),
      platform: _field(defaultTargetPlatform.name.toLowerCase()),
      osVersion: _field(osVersion),
      screen: _field(screen),
      locale: _field(locale),
    );
  }

  /// Opens a thread with the rider's message on it and returns the receipt.
  /// Throws the underlying `GrpcError` so the bloc can distinguish a spent
  /// quota from a transport failure.
  Future<FeedbackReceipt> submit({
    required FeedbackCategory category,
    required String body,
    required FeedbackDiagnostics diagnostics,
  }) async {
    final receipt = await _grpc.postFeedback(
      pb.PostFeedbackRequest(
        installId: await InstallIdentity.getOrCreate(),
        category: category.wire,
        body: body,
        diagnostics: pb.ReportDiagnostics(
          appVersion: diagnostics.appVersion,
          platform: diagnostics.platform,
          osVersion: diagnostics.osVersion,
          screen: diagnostics.screen,
          locale: diagnostics.locale,
        ),
      ),
      options: await FirebaseCallOptions.build(),
    );
    return FeedbackReceipt(
      threadId: receipt.threadId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        receipt.createdAtUnix.toInt() * 1000,
      ),
    );
  }

  /// Normalises one diagnostics value to what the server accepts: trimmed,
  /// single-line, and within the length limit.
  static String _field(String value) {
    final flattened = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flattened.length <= _diagnosticsFieldLimit
        ? flattened
        : flattened.substring(0, _diagnosticsFieldLimit);
  }
}

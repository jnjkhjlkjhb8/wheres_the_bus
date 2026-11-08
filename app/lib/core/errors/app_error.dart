import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:grpc/grpc.dart';
import 'package:http/http.dart' show ClientException;
import 'package:wheres_the_bus/l10n/app_i18n.dart';

/// Implements [Exception] so repositories can throw it directly rather than
/// wrapping it in a second error type on the way out.
sealed class AppError implements Exception {
  const AppError();

  factory AppError.from(Object e) => switch (e) {
    final AppError error => error,
    SocketException() || ClientException() => const OfflineError(),
    TimeoutException() => const TimeoutError(),
    final GrpcError error => _fromGrpc(error),
    final DioException error => _fromDio(error),
    _ => const UnknownError(),
  };

  static AppError _fromGrpc(GrpcError e) => switch (e.code) {
    StatusCode.unavailable => const OfflineError(),
    StatusCode.deadlineExceeded => const TimeoutError(),
    StatusCode.notFound => const NotFoundError(),
    // A dropped HTTP/2 connection arrives as UNKNOWN carrying the transport
    // error's text; the stream reconnects, so it is not a server fault.
    StatusCode.unknown when _isConnectionDrop(e) => const OfflineError(),
    _ => ServerError(e.code),
  };

  static bool _isConnectionDrop(GrpcError e) =>
      e.message?.startsWith('HTTP/2 error: Connection error') ?? false;

  static AppError _fromDio(DioException e) => switch (e.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout => const TimeoutError(),
    DioExceptionType.connectionError => const OfflineError(),
    DioExceptionType.badResponse when e.response?.statusCode == 404 =>
      const NotFoundError(),
    _ => const UnknownError(),
  };

  /// Offline, timeout and not-found are outcomes the app already handles, not
  /// defects, so crash reports leave them out.
  bool get reportable => switch (this) {
    OfflineError() || TimeoutError() || NotFoundError() => false,
    ServerError() || UnknownError() => true,
  };

  String titleOf(AppI18n i18n);
  String hintOf(AppI18n i18n);
  IconData get icon;
}

class OfflineError extends AppError {
  const OfflineError();

  @override
  String titleOf(AppI18n i18n) => i18n.errorOfflineTitle;

  @override
  String hintOf(AppI18n i18n) => i18n.errorOfflineHint;

  @override
  IconData get icon => Icons.cloud_off_rounded;
}

class TimeoutError extends AppError {
  const TimeoutError();

  @override
  String titleOf(AppI18n i18n) => i18n.errorTimeoutTitle;

  @override
  String hintOf(AppI18n i18n) => i18n.errorTimeoutHint;

  @override
  IconData get icon => Icons.hourglass_empty_rounded;
}

class NotFoundError extends AppError {
  const NotFoundError();

  @override
  String titleOf(AppI18n i18n) => i18n.errorNotFoundTitle;

  @override
  String hintOf(AppI18n i18n) => i18n.errorNotFoundHint;

  @override
  IconData get icon => Icons.search_off_rounded;
}

class ServerError extends AppError {
  const ServerError(this.code);

  final int code;

  @override
  String titleOf(AppI18n i18n) => i18n.errorServerTitle;

  @override
  String hintOf(AppI18n i18n) => i18n.errorServerHint;

  @override
  IconData get icon => Icons.error_outline_rounded;
}

class UnknownError extends AppError {
  const UnknownError();

  @override
  String titleOf(AppI18n i18n) => i18n.errorUnknownTitle;

  @override
  String hintOf(AppI18n i18n) => i18n.errorUnknownHint;

  @override
  IconData get icon => Icons.error_outline_rounded;
}

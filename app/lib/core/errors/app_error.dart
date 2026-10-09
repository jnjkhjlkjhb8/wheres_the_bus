import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

/// Implements [Exception] so repositories can throw it directly rather than
/// wrapping it in a second error type on the way out.
sealed class AppError implements Exception {
  const AppError();

  factory AppError.from(Object e) {
    if (e is AppError) return e;
    if (e is SocketException) return const OfflineError();
    if (e is TimeoutException) return const TimeoutError();
    if (e is GrpcError) {
      return switch (e.code) {
        StatusCode.unavailable => const OfflineError(),
        StatusCode.deadlineExceeded => const TimeoutError(),
        StatusCode.notFound => const NotFoundError(),
        _ => ServerError(e.code),
      };
    }
    return const UnknownError();
  }

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

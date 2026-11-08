import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart' show GrpcError, StatusCode;
import 'package:http/http.dart' show ClientException;
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/l10n/app_i18n_zh.dart';

void main() {
  test('network failures outside gRPC map to OfflineError', () {
    expect(AppError.from(const SocketException('down')), isA<OfflineError>());
    expect(
      AppError.from(ClientException('Connection closed while receiving data')),
      isA<OfflineError>(),
    );
  });

  test('a TimeoutException maps to TimeoutError', () {
    expect(AppError.from(TimeoutException('slow')), isA<TimeoutError>());
  });

  test('a dropped HTTP/2 connection maps to OfflineError', () {
    const drop = GrpcError.unknown(
      'HTTP/2 error: Connection error: Connection is being forcefully '
      'terminated. (errorCode: 10)',
    );
    expect(AppError.from(drop), isA<OfflineError>());
    expect(AppError.from(const GrpcError.unknown('boom')), isA<ServerError>());
    expect(AppError.from(const GrpcError.unknown()), isA<ServerError>());
  });

  group('dio', () {
    final options = RequestOptions(path: '/manifest');
    DioException dio(DioExceptionType type, [int? status]) => DioException(
      requestOptions: options,
      type: type,
      response: status == null
          ? null
          : Response<void>(requestOptions: options, statusCode: status),
    );

    test('timeouts map to TimeoutError', () {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      ]) {
        expect(AppError.from(dio(type)), isA<TimeoutError>(), reason: '$type');
      }
    });

    test('a connection error maps to OfflineError', () {
      expect(
        AppError.from(dio(DioExceptionType.connectionError)),
        isA<OfflineError>(),
      );
    });

    test('a 404 maps to NotFoundError, anything else to UnknownError', () {
      expect(
        AppError.from(dio(DioExceptionType.badResponse, 404)),
        isA<NotFoundError>(),
      );
      expect(
        AppError.from(dio(DioExceptionType.badResponse, 500)),
        isA<UnknownError>(),
      );
      expect(AppError.from(dio(DioExceptionType.cancel)), isA<UnknownError>());
    });
  });

  test('only defects are reportable', () {
    expect(const OfflineError().reportable, isFalse);
    expect(const TimeoutError().reportable, isFalse);
    expect(const NotFoundError().reportable, isFalse);
    expect(const ServerError(13).reportable, isTrue);
    expect(const UnknownError().reportable, isTrue);
  });

  test('grpc unavailable maps to OfflineError', () {
    expect(AppError.from(const GrpcError.unavailable()), isA<OfflineError>());
  });

  test('grpc deadlineExceeded maps to TimeoutError', () {
    expect(
      AppError.from(const GrpcError.deadlineExceeded()),
      isA<TimeoutError>(),
    );
  });

  test('grpc notFound maps to NotFoundError', () {
    expect(AppError.from(const GrpcError.notFound()), isA<NotFoundError>());
  });

  test('other grpc codes map to ServerError with code', () {
    final e = AppError.from(const GrpcError.internal());
    expect(e, isA<ServerError>());
    expect((e as ServerError).code, StatusCode.internal);
  });

  test('arbitrary exception maps to UnknownError', () {
    expect(AppError.from(StateError('x')), isA<UnknownError>());
  });

  test('AppError passes through unchanged', () {
    const offline = OfflineError();
    expect(AppError.from(offline), same(offline));
  });

  test('every error has copy', () {
    // The zh-TW template is the source of truth for copy; en falls back to it
    // until Crowdin returns translations, so an empty string here would be a
    // missing ARB key rather than a missing translation.
    final i18n = AppI18nZh();
    for (final e in [
      const OfflineError(),
      const TimeoutError(),
      const NotFoundError(),
      const ServerError(13),
      const UnknownError(),
    ]) {
      expect(e.titleOf(i18n), isNotEmpty);
      expect(e.hintOf(i18n), isNotEmpty);
    }
  });
}

// Typed API error wrapper.
//
// Every error response from the Go server lands in the same envelope:
//   { "error": "...", "code": "...", "_debug": { "raw": "...", "where": "..." } }
//
// ApiError lifts that into Dart so the UI doesn't have to grub through
// DioException's untyped Map. Code is the stable identifier — branch on
// it. Message is the safe display text — render it. Debug is optional
// and only present when the server is in DEV_VERBOSE_ERRORS mode; the UI
// further gates the debug chip on kDebugMode so an accidentally-flagged
// prod build still hides it.

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class ApiDebug {
  /// The server-side error's full Error() text — DB constraint info,
  /// constraint names, the lot. Never displayed in production.
  final String raw;
  /// Free-form caller hint (typically the store method name). Empty
  /// when the server didn't supply one.
  final String where;
  const ApiDebug({required this.raw, required this.where});
}

class ApiError implements Exception {
  /// Stable machine-readable identifier. UIs branch on this — never on
  /// [message]. `internal` means the server couldn't classify the error;
  /// `validation` covers BadRequest-style failures with safe message text.
  final String code;
  /// Safe, user-facing message. Show it verbatim in snackbars / error
  /// rows; concatenating it with other text is fine.
  final String message;
  /// HTTP status code. Useful for differentiating 404 vs 409 vs 500
  /// when the same handler can return multiple, and for retry logic.
  final int? status;
  /// Optional debug payload — only present when the server is configured
  /// with `DEV_VERBOSE_ERRORS=1` (or `FIREBASE_AUTH_EMULATOR_HOST`, which
  /// implies dev). Null in production responses.
  final ApiDebug? debug;

  const ApiError({
    required this.code,
    required this.message,
    this.status,
    this.debug,
  });

  /// True when the client should render the dev debug chip — both gates
  /// must pass: the server included debug info AND the client is built
  /// in debug mode. Double-gating so a misconfigured prod build still
  /// hides the raw error from users.
  bool get showDebug => debug != null && kDebugMode;

  /// Build an ApiError from a [DioException]. Falls back to a generic
  /// network error when the response shape doesn't match — we never
  /// throw from this constructor, since the caller is already in a
  /// catch block trying to recover.
  factory ApiError.fromDio(DioException e) {
    final data = e.response?.data;
    final status = e.response?.statusCode;
    if (data is Map) {
      final code = data['code'] as String? ?? 'internal';
      final message = data['error'] as String? ??
          'Something went wrong. Please try again.';
      ApiDebug? debug;
      final rawDebug = data['_debug'];
      if (rawDebug is Map) {
        debug = ApiDebug(
          raw: (rawDebug['raw'] as String?) ?? '',
          where: (rawDebug['where'] as String?) ?? '',
        );
      }
      return ApiError(
        code: code,
        message: message,
        status: status,
        debug: debug,
      );
    }
    return ApiError(
      code: 'network',
      message: e.message ?? 'Network error.',
      status: status,
    );
  }

  /// Lift any thrown object into an ApiError. Pass-through for objects
  /// that are already ApiError so existing throw-rethrow paths don't get
  /// double-wrapped. Anything that isn't a DioException becomes a
  /// generic `unknown` error carrying the toString — same shape so the
  /// UI can render it through the same display helper.
  factory ApiError.fromAny(Object e) {
    if (e is ApiError) return e;
    if (e is DioException) return ApiError.fromDio(e);
    return ApiError(
      code: 'unknown',
      message: 'Something went wrong.',
      debug: kDebugMode ? ApiDebug(raw: '$e', where: '') : null,
    );
  }

  @override
  String toString() => 'ApiError($code, status=$status): $message';
}

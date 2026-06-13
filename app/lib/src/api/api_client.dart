// Thin Dio wrapper around the Go backend.
//
// Every request gets the current Firebase ID token via an interceptor — the
// token refreshes automatically. When no user is signed in, requests still
// fire but the server will respond 401, which the UI handles by routing
// back to sign-in.

import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'models.dart';

const _devBaseUrl = 'http://localhost:8080/api/v1';

class ApiClient {
  final Dio _dio;
  ApiClient(this._dio);

  /// Escape hatch for callers that need to fire a one-off raw request.
  /// Keeps the auth interceptor + base URL in scope.
  Dio get raw => _dio;

  factory ApiClient.create() {
    final dio = Dio(BaseOptions(
      baseUrl: _devBaseUrl,
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
    ));
    dio.interceptors.add(_AuthInterceptor());
    if (kDebugMode) {
      dio.interceptors.add(LogInterceptor(responseBody: false));
    }
    return ApiClient(dio);
  }

  Future<StudioConfig> studioConfig() async {
    final r = await _dio.get<Map<String, dynamic>>('/studio/config');
    return StudioConfig.fromJson(r.data!);
  }

  Future<Me> me() async {
    final r = await _dio.get<Map<String, dynamic>>('/me');
    return Me.fromJson(r.data!);
  }

  Future<List<ClassRow>> classesForDay(DateTime day) async {
    final r = await _dio.get<List<dynamic>>(
      '/classes',
      queryParameters: {'date': _ymd(day)},
    );
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(ClassRow.fromJson)
        .toList();
  }

  Future<ClassDetail> getClass(String id) async {
    final r = await _dio.get<Map<String, dynamic>>('/classes/$id');
    return ClassDetail.fromJson(r.data!);
  }

  Future<Product> getProduct(String id) async {
    final r = await _dio.get<Map<String, dynamic>>('/products/$id');
    return Product.fromJson(r.data!);
  }

  /// Range is [from, to) by calendar day.
  Future<List<ClassRow>> classesInRange({
    required DateTime from,
    required DateTime to,
  }) async {
    final r = await _dio.get<List<dynamic>>(
      '/classes',
      queryParameters: {'from': _ymd(from), 'to': _ymd(to)},
    );
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(ClassRow.fromJson)
        .toList();
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<List<EnrollmentSummary>> listEnrollments() async {
    final r = await _dio.get<List<dynamic>>('/enrollments');
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(EnrollmentSummary.fromJson)
        .toList();
  }

  Future<EnrollmentDetail> getEnrollment(String id) async {
    final r = await _dio.get<Map<String, dynamic>>('/enrollments/$id');
    return EnrollmentDetail.fromJson(r.data!);
  }

  Future<void> joinEnrollment(String id) async {
    await _dio.post<void>(
      '/enrollments/$id/join',
      data: {'payment_method': 'dev_stub'},
    );
  }

  Future<List<EligibleEntitlement>> eligibleEntitlements(String classId) async {
    final r = await _dio.get<List<dynamic>>(
      '/classes/$classId/eligible-entitlements',
    );
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(EligibleEntitlement.fromJson)
        .toList();
  }

  Future<List<UpcomingBooking>> upcomingBookings() async {
    final r = await _dio.get<List<dynamic>>(
      '/bookings',
      queryParameters: {'scope': 'upcoming'},
    );
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(UpcomingBooking.fromJson)
        .toList();
  }

  Future<List<UpcomingBooking>> pastBookings() async {
    final r = await _dio.get<List<dynamic>>(
      '/bookings',
      queryParameters: {'scope': 'past'},
    );
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(UpcomingBooking.fromJson)
        .toList();
  }

  /// Returns the new booking ID.
  /// Throws [BookingConflict] if the server rejects (409).
  Future<String> createBooking({
    required String classId,
    required String entitlementId,
    bool plusOne = false,
  }) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/bookings',
        data: {
          'class_id': classId,
          'entitlement_id': entitlementId,
          'plus_one': plusOne,
        },
      );
      return r.data!['id'] as String;
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        final data = e.response?.data as Map<String, dynamic>?;
        throw BookingConflict(
          code: data?['code'] as String? ?? 'conflict',
          message: data?['error'] as String? ?? 'Booking refused',
        );
      }
      rethrow;
    }
  }

  Future<void> cancelBooking(String bookingId) async {
    await _dio.delete<void>('/bookings/$bookingId');
  }

  Future<List<Product>> listProducts() async {
    final r = await _dio.get<List<dynamic>>('/products');
    return r.data!.cast<Map<String, dynamic>>().map(Product.fromJson).toList();
  }

  Future<PurchaseResult> createPurchase({
    required String productId,
    String paymentMethod = 'dev_stub',
  }) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/purchases',
      data: {'product_id': productId, 'payment_method': paymentMethod},
    );
    return PurchaseResult.fromJson(r.data!);
  }

  Future<List<WalletEntitlement>> myEntitlements() async {
    final r = await _dio.get<List<dynamic>>('/me/entitlements');
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(WalletEntitlement.fromJson)
        .toList();
  }

  Future<List<WalletPurchase>> myPurchases() async {
    final r = await _dio.get<List<dynamic>>(
      '/purchases',
      queryParameters: {'scope': 'mine'},
    );
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(WalletPurchase.fromJson)
        .toList();
  }

  Future<AttendanceSummary> myAttendance() async {
    final r = await _dio.get<Map<String, dynamic>>('/me/attendance');
    return AttendanceSummary.fromJson(r.data!);
  }

  Future<CheckInPayload> checkInCode() async {
    final r = await _dio.get<Map<String, dynamic>>('/me/checkin-code');
    return CheckInPayload.fromJson(r.data!);
  }

  Future<List<NotificationItem>> notificationsFeed() async {
    final r = await _dio.get<List<dynamic>>('/me/notifications/feed');
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(NotificationItem.fromJson)
        .toList();
  }

  Future<void> markNotificationRead(String id) async {
    await _dio.post<void>('/me/notifications/$id/read');
  }

  Future<void> markAllNotificationsRead() async {
    await _dio.post<Map<String, dynamic>>('/me/notifications/read-all');
  }

  /// Returns the assigned 1-based waitlist position.
  Future<int> joinWaitlist(String classId) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/classes/$classId/waitlist',
    );
    return r.data!['position'] as int;
  }

  // ---- manager / admin ----

  Future<AdminDashboard> adminDashboard() async {
    final r = await _dio.get<Map<String, dynamic>>('/admin/dashboard');
    return AdminDashboard.fromJson(r.data!);
  }

  Future<List<ClassRow>> adminClasses({
    required DateTime from,
    required DateTime to,
  }) async {
    String iso(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final r = await _dio.get<List<dynamic>>(
      '/admin/classes',
      queryParameters: {'from': iso(from), 'to': iso(to)},
    );
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(ClassRow.fromJson)
        .toList();
  }

  Future<Roster> adminRoster(String classId) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/admin/classes/$classId/roster',
    );
    return Roster.fromJson(r.data!);
  }

  /// status: 'present' | 'no_show' | 'booked' (undo)
  Future<void> markAttendance({
    required String bookingId,
    required String status,
    String via = 'manual',
  }) async {
    await _dio.post<void>(
      '/admin/bookings/$bookingId/attendance',
      data: {'status': status, 'via': via},
    );
  }

  Future<PromoteResult> promoteWaitlist(String classId) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/classes/$classId/promote',
    );
    return PromoteResult.fromJson(r.data!);
  }

  /// Marks a student's booking as attended via barcode/QR scan. Throws
  /// [ScanConflict] on a typed refusal (invalid_token, no_booking, etc.).
  Future<ScanResult> adminCheckinScan({
    required String token,
    required String classId,
  }) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/admin/checkin/scan',
        data: {'token': token, 'class_id': classId},
      );
      return ScanResult.fromJson(r.data!);
    } on DioException catch (e) {
      final code = e.response?.statusCode ?? 0;
      if (code == 404 || code == 409) {
        final data = e.response?.data as Map<String, dynamic>?;
        throw ScanConflict(
          code: data?['code'] as String? ?? 'conflict',
          message: data?['error'] as String? ?? 'Scan refused',
        );
      }
      rethrow;
    }
  }

  // ---- themes + studio settings ----

  Future<List<ThemeRow>> adminListThemes() async {
    final r = await _dio.get<List<dynamic>>('/admin/themes');
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(ThemeRow.fromJson)
        .toList();
  }

  Future<void> adminUpdateThemeTokens({
    required String themeId,
    required Map<String, String> tokens,
  }) async {
    await _dio.patch<void>('/admin/themes/$themeId', data: {'tokens': tokens});
  }

  Future<void> adminActivateTheme(String themeId) async {
    await _dio.post<void>('/admin/themes/$themeId/activate');
  }

  Future<List<AdminProduct>> adminListProducts() async {
    final r = await _dio.get<List<dynamic>>('/admin/products');
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(AdminProduct.fromJson)
        .toList();
  }

  Future<String> adminCreateProduct(Map<String, dynamic> body) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/products',
      data: body,
    );
    return r.data!['id'] as String;
  }

  Future<void> adminUpdateProduct(
    String id,
    Map<String, dynamic> patch,
  ) async {
    await _dio.patch<void>('/admin/products/$id', data: patch);
  }

  Future<void> adminArchiveProduct(String id) async {
    await _dio.delete<void>('/admin/products/$id');
  }

  Future<List<AdminEnrollmentSummary>> adminListEnrollments() async {
    final r = await _dio.get<List<dynamic>>('/admin/enrollments');
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(AdminEnrollmentSummary.fromJson)
        .toList();
  }

  Future<String> adminCreateSeries(Map<String, dynamic> body) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/enrollments',
      data: body,
    );
    return r.data!['enrollment_id'] as String;
  }

  Future<void> adminUpdateEnrollment({
    required String enrollmentId,
    String? title,
    String? description,
    int? capacity,
  }) async {
    final body = <String, dynamic>{};
    if (title != null) body['title'] = title;
    if (description != null) body['description'] = description;
    if (capacity != null) body['capacity'] = capacity;
    await _dio.patch<void>('/admin/enrollments/$enrollmentId', data: body);
  }

  Future<SeriesRoster> adminSeriesRoster(String enrollmentId) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/admin/enrollments/$enrollmentId/roster',
    );
    return SeriesRoster.fromJson(r.data!);
  }

  Future<List<AdminInstructor>> adminListInstructors() async {
    final r = await _dio.get<List<dynamic>>('/admin/instructors');
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(AdminInstructor.fromJson)
        .toList();
  }

  Future<List<AdminRoom>> adminListRooms() async {
    final r = await _dio.get<List<dynamic>>('/admin/rooms');
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(AdminRoom.fromJson)
        .toList();
  }

  Future<String> adminCreateClass(Map<String, dynamic> body) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/classes',
      data: body,
    );
    return r.data!['id'] as String;
  }

  Future<CancelClassResult> adminCancelClass(String id) async {
    final r = await _dio.delete<Map<String, dynamic>>('/admin/classes/$id');
    return CancelClassResult.fromJson(r.data!);
  }

  Future<ClassTemplate> adminCreateClassTemplate(Map<String, dynamic> body) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/class-templates',
      data: body,
    );
    return ClassTemplate.fromJson(r.data!);
  }

  Future<List<ClassTemplate>> adminListClassTemplates() async {
    final r = await _dio.get<List<dynamic>>('/admin/class-templates');
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(ClassTemplate.fromJson)
        .toList();
  }

  Future<UndoTemplateResult> adminUndoClassTemplate(String id) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/class-templates/$id/undo',
    );
    return UndoTemplateResult.fromJson(r.data!);
  }

  Future<List<AuditEntry>> adminAudit({String? action}) async {
    final r = await _dio.get<List<dynamic>>(
      '/admin/audit',
      queryParameters:
          action == null || action == 'all' ? null : {'action': action},
    );
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(AuditEntry.fromJson)
        .toList();
  }

  Future<AdminReports> adminReports() async {
    final r = await _dio.get<Map<String, dynamic>>('/admin/reports');
    return AdminReports.fromJson(r.data!);
  }

  Future<AdminStudentsList> adminListStudents({String? query}) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/admin/students',
      queryParameters: query == null || query.isEmpty ? null : {'q': query},
    );
    return AdminStudentsList.fromJson(r.data!);
  }

  Future<AdminStudentDetail> adminGetStudent(String id) async {
    final r = await _dio.get<Map<String, dynamic>>('/admin/students/$id');
    return AdminStudentDetail.fromJson(r.data!);
  }

  Future<Map<String, dynamic>> adminGrantPass({
    required String studentId,
    required String productId,
    required String paymentMethod,
    int? amountMinor,
    String? note,
  }) async {
    final body = <String, dynamic>{
      'product_id': productId,
      'payment_method': paymentMethod,
    };
    if (amountMinor != null) body['amount_minor'] = amountMinor;
    if (note != null && note.isNotEmpty) body['note'] = note;
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/students/$studentId/grant',
      data: body,
    );
    return r.data!;
  }

  Future<void> adminAdjustCredits({
    required String studentId,
    required String entitlementId,
    required int delta,
    required String reason,
  }) async {
    await _dio.post<void>(
      '/admin/students/$studentId/entitlements/$entitlementId/adjust',
      data: {'delta': delta, 'reason': reason},
    );
  }

  Future<Map<String, dynamic>> adminVoidEntitlement({
    required String entitlementId,
    required String refund, // none | unused | full
    required String reason,
  }) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/entitlements/$entitlementId/void',
      data: {'refund': refund, 'reason': reason},
    );
    return r.data!;
  }

  Future<List<ClassType>> adminListClassTypes() async {
    final r = await _dio.get<List<dynamic>>('/admin/class-types');
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(ClassType.fromJson)
        .toList();
  }

  Future<String> adminCreateClassType({
    required String name,
    String discipline = '',
  }) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/class-types',
      data: {'name': name, 'discipline': discipline},
    );
    return r.data!['id'] as String;
  }

  Future<void> adminUpdateClassType({
    required String id,
    required String name,
    String discipline = '',
  }) async {
    await _dio.patch<void>(
      '/admin/class-types/$id',
      data: {'name': name, 'discipline': discipline},
    );
  }

  // ---- staff ----

  Future<List<StaffMember>> adminListStaff() async {
    final r = await _dio.get<List<dynamic>>('/admin/staff');
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(StaffMember.fromJson)
        .toList();
  }

  Future<String> adminCreateStaff({
    required String role,
    required String email,
    required String fullName,
    String photoUrl = '',
  }) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/staff',
      data: {
        'role': role,
        'email': email,
        'full_name': fullName,
        'photo_url': photoUrl,
      },
    );
    return r.data!['id'] as String;
  }

  Future<void> adminUpdateStaff({
    required String id,
    required String role,
    required String email,
    required String fullName,
    String photoUrl = '',
  }) async {
    await _dio.patch<void>(
      '/admin/staff/$id',
      data: {
        'role': role,
        'email': email,
        'full_name': fullName,
        'photo_url': photoUrl,
      },
    );
  }

  // ---- promotions ----

  Future<List<Promotion>> listPromotions() async {
    final r = await _dio.get<List<dynamic>>('/promotions');
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(Promotion.fromJson)
        .toList();
  }

  Future<List<Promotion>> adminListPromotions() async {
    final r = await _dio.get<List<dynamic>>('/admin/promotions');
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(Promotion.fromJson)
        .toList();
  }

  Future<String> adminCreatePromotion({
    required String title,
    String body = '',
    String imageUrl = '',
    DateTime? startsAt,
    DateTime? endsAt,
  }) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/promotions',
      data: _promotionBody(
        title: title,
        body: body,
        imageUrl: imageUrl,
        startsAt: startsAt,
        endsAt: endsAt,
      ),
    );
    return r.data!['id'] as String;
  }

  Future<void> adminUpdatePromotion({
    required String id,
    required String title,
    String body = '',
    String imageUrl = '',
    DateTime? startsAt,
    DateTime? endsAt,
  }) async {
    await _dio.patch<void>(
      '/admin/promotions/$id',
      data: _promotionBody(
        title: title,
        body: body,
        imageUrl: imageUrl,
        startsAt: startsAt,
        endsAt: endsAt,
      ),
    );
  }

  Future<void> adminArchivePromotion(String id) async {
    await _dio.delete<void>('/admin/promotions/$id');
  }

  static Map<String, dynamic> _promotionBody({
    required String title,
    required String body,
    required String imageUrl,
    DateTime? startsAt,
    DateTime? endsAt,
  }) => {
    'title': title,
    'body': body,
    'image_url': imageUrl,
    'starts_at': startsAt?.toUtc().toIso8601String(),
    'ends_at': endsAt?.toUtc().toIso8601String(),
  };

  Future<void> adminUpdateStudioConfig({
    int? freeCancelCutoffHours,
    bool? allowStudentPlusOne,
    String? buyLayout,
    String? welcomeMessage,
  }) async {
    final body = <String, dynamic>{};
    if (freeCancelCutoffHours != null) {
      body['free_cancel_cutoff_hours'] = freeCancelCutoffHours;
    }
    if (allowStudentPlusOne != null) {
      body['allow_student_plus_one'] = allowStudentPlusOne;
    }
    if (buyLayout != null) body['buy_layout'] = buyLayout;
    if (welcomeMessage != null) body['welcome_message'] = welcomeMessage;
    await _dio.patch<void>('/admin/studio/config', data: body);
  }
}

/// Injects the current Firebase ID token on every outgoing request. On 401,
/// forces a token refresh and retries once (handles silent expiry).
class _AuthInterceptor extends Interceptor {
  bool _retrying = false;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final token = await user.getIdToken();
      if (token != null) {
        options.headers['Authorization'] = 'Bearer $token';
      }
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final res = err.response;
    if (res?.statusCode == 401 && !_retrying) {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        _retrying = true;
        try {
          final fresh = await user.getIdToken(true);
          if (fresh != null) {
            final retried = await Dio().fetch<dynamic>(
              err.requestOptions
                ..headers['Authorization'] = 'Bearer $fresh',
            );
            return handler.resolve(retried);
          }
        } catch (_) {
          // fall through to original error
        } finally {
          _retrying = false;
        }
      }
    }
    handler.next(err);
  }
}

final apiClientProvider = Provider<ApiClient>((_) => ApiClient.create());

/// Bootstrap call: studio config + me, in parallel.
class Bootstrap {
  final StudioConfig studio;
  final Me me;
  Bootstrap(this.studio, this.me);
}

final bootstrapProvider = FutureProvider<Bootstrap>((ref) async {
  final api = ref.watch(apiClientProvider);
  final results = await Future.wait([api.studioConfig(), api.me()]);
  return Bootstrap(results[0] as StudioConfig, results[1] as Me);
});

class BookingConflict implements Exception {
  final String code;
  final String message;
  BookingConflict({required this.code, required this.message});
  @override
  String toString() => 'BookingConflict($code): $message';
}

class ScanConflict implements Exception {
  final String code;
  final String message;
  ScanConflict({required this.code, required this.message});
  @override
  String toString() => 'ScanConflict($code): $message';
}

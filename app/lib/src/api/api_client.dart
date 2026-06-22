// Thin Dio wrapper around the Go backend.
//
// Every request gets the current Firebase ID token via an interceptor — the
// token refreshes automatically. When no user is signed in, requests still
// fire but the server will respond 401, which the UI handles by routing
// back to sign-in.

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_state.dart';
import 'api_error.dart';
import 'models.dart';

// Dev base URL goes through the Caddy reverse proxy at
// https://localhost:5443. Same origin as the Flutter dev server (also
// proxied), which eliminates the per-request CORS OPTIONS preflight,
// AND gives the app a real TLS endpoint so service workers / secure
// cookies / HTTP/2 behave the way they will in prod.
//
// Bypass path: if Caddy isn't running and you want to talk straight to
// the Go server, switch this to `http://localhost:8080/api/v1`. The
// browser will then need CORS preflight + plain HTTP, and you lose the
// dev/prod parity wins.
const _devBaseUrl = 'https://localhost:5443/api/v1';

class ApiClient {
  final Dio _dio;
  ApiClient(this._dio);

  /// Escape hatch for callers that need to fire a one-off raw request.
  /// Keeps the auth interceptor + base URL in scope.
  Dio get raw => _dio;

  factory ApiClient.create() {
    final dio = Dio(
      BaseOptions(
        baseUrl: _devBaseUrl,
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
      ),
    );
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
    return r.data!.cast<Map<String, dynamic>>().map(ClassRow.fromJson).toList();
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
    return r.data!.cast<Map<String, dynamic>>().map(ClassRow.fromJson).toList();
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
    String plusOneName = '',
  }) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/bookings',
        data: {
          'class_id': classId,
          'entitlement_id': entitlementId,
          'plus_one': plusOne,
          if (plusOne) 'plus_one_name': plusOneName,
        },
      );
      return r.data!['id'] as String;
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        final base = ApiError.fromDio(e);
        throw BookingConflict(
          code: base.code,
          message: base.message,
          status: base.status,
          debug: base.debug,
        );
      }
      rethrow;
    }
  }

  Future<void> cancelBooking(String bookingId) async {
    await _dio.delete<void>('/bookings/$bookingId');
  }

  /// Ask the server what would happen if this booking were cancelled now.
  /// Used by the cancel confirmation dialog so the warning the user sees
  /// matches what the server will actually do, with no client-side time
  /// math that could drift.
  Future<CancelPreview> cancelPreview(String bookingId) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/bookings/$bookingId/cancel-preview',
    );
    return CancelPreview.fromJson(r.data!);
  }

  /// Ask the server what's permitted for a (class, entitlement) pair.
  /// Tells the UI whether the user can book at all, whether +1 is
  /// eligible (and why not if it isn't), and how many credits they have
  /// — without the client duplicating any eligibility logic.
  Future<BookingPreview> bookingPreview({
    required String classId,
    required String entitlementId,
  }) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/bookings/preview',
      queryParameters: {'class_id': classId, 'entitlement_id': entitlementId},
    );
    return BookingPreview.fromJson(r.data!);
  }

  Future<List<Product>> listProducts({String? coversClassTypeId}) async {
    final r = await _dio.get<List<dynamic>>(
      '/products',
      queryParameters: {
        if (coversClassTypeId != null) 'covers_class_type': coversClassTypeId,
      },
    );
    return r.data!.cast<Map<String, dynamic>>().map(Product.fromJson).toList();
  }

  Future<PurchaseResult> createPurchase({
    required String productId,
    String paymentMethod = 'dev_stub',
    String? discountCode,
  }) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/purchases',
        data: {
          'product_id': productId,
          'payment_method': paymentMethod,
          if (discountCode != null && discountCode.isNotEmpty)
            'discount_code': discountCode,
        },
      );
      return PurchaseResult.fromJson(r.data!);
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        final data = e.response?.data as Map<String, dynamic>?;
        throw BookingConflict(
          code: data?['code'] as String? ?? 'conflict',
          message: data?['error'] as String? ?? 'Purchase refused',
        );
      }
      rethrow;
    }
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

  /// Register an FCM device token with the server. Call this once
  /// firebase_messaging is wired and `getToken()` returns a value; safe to
  /// re-call on token refresh — the server upserts on the token column.
  Future<List<Achievement>> myAchievements() async {
    final r = await _dio.get<List<dynamic>>('/me/achievements');
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(Achievement.fromJson)
        .toList();
  }

  Future<void> registerDevice({
    required String fcmToken,
    String? platform,
  }) async {
    await _dio.post<void>(
      '/me/devices',
      data: {'fcm_token': fcmToken, if (platform != null) 'platform': platform},
    );
  }

  // ---- manager: stripe credentials ----

  Future<StripeCredentialsView> adminStripeCredentials() async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/admin/studio/stripe-credentials',
    );
    return StripeCredentialsView.fromJson(r.data!);
  }

  /// Partial update. Keys not in [patch] are left untouched on the server.
  /// To clear a previously-set secret, send the field with value `""`.
  Future<StripeCredentialsView> adminUpdateStripeCredentials(
    Map<String, dynamic> patch,
  ) async {
    final r = await _dio.patch<Map<String, dynamic>>(
      '/admin/studio/stripe-credentials',
      data: patch,
    );
    return StripeCredentialsView.fromJson(r.data!);
  }

  Future<NotificationPrefs> notificationPrefs() async {
    final r = await _dio.get<Map<String, dynamic>>('/me/notifications');
    return NotificationPrefs.fromJson(r.data!);
  }

  /// Partial update — only the fields supplied are flipped on the server.
  Future<NotificationPrefs> updateNotificationPrefs(
    Map<String, bool> patch,
  ) async {
    final r = await _dio.patch<Map<String, dynamic>>(
      '/me/notifications',
      data: patch,
    );
    return NotificationPrefs.fromJson(r.data!);
  }

  Future<void> markNotificationRead(String id) async {
    await _dio.post<void>('/me/notifications/$id/read');
  }

  Future<void> markAllNotificationsRead() async {
    await _dio.post<Map<String, dynamic>>('/me/notifications/read-all');
  }

  // ---- chat ----

  /// Every conversation the caller belongs to, newest-activity first, each
  /// with its members, last-message preview, and the caller's unread count.
  Future<List<Conversation>> conversations() async {
    final r = await _dio.get<List<dynamic>>('/conversations');
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(Conversation.fromJson)
        .toList();
  }

  /// A page of messages, oldest→newest. Pass [before] (a seq) to scroll back
  /// into history, or [after] to fetch only messages newer than a seq (the
  /// poll). [limit] defaults to 30 server-side.
  Future<List<ChatMessage>> messages(
    String conversationId, {
    int? before,
    int? after,
    int? limit,
  }) async {
    final r = await _dio.get<List<dynamic>>(
      '/conversations/$conversationId/messages',
      queryParameters: {
        if (before != null) 'before': before,
        if (after != null) 'after': after,
        if (limit != null) 'limit': limit,
      },
    );
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(ChatMessage.fromJson)
        .toList();
  }

  /// Create a group room (staff only). [memberIds] are the initial members
  /// besides the creator, who is always added.
  Future<Conversation> createGroup({
    required String title,
    List<String> memberIds = const [],
  }) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/conversations',
      data: {'kind': 'group', 'title': title, 'member_ids': memberIds},
    );
    return Conversation.fromJson(r.data!);
  }

  /// Open (or reuse) a direct message with [userId] (staff only).
  Future<Conversation> openDm(String userId) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/conversations',
      data: {'kind': 'dm', 'user_id': userId},
    );
    return Conversation.fromJson(r.data!);
  }

  Future<void> addConversationMembers(
    String conversationId,
    List<String> memberIds,
  ) async {
    await _dio.post<void>(
      '/conversations/$conversationId/members',
      data: {'member_ids': memberIds},
    );
  }

  Future<ChatMessage> sendMessage(String conversationId, String body) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/conversations/$conversationId/messages',
      data: {'body': body},
    );
    return ChatMessage.fromJson(r.data!);
  }

  Future<ChatMessage> editMessage(
    String conversationId,
    String messageId,
    String body,
  ) async {
    final r = await _dio.patch<Map<String, dynamic>>(
      '/conversations/$conversationId/messages/$messageId',
      data: {'body': body},
    );
    return ChatMessage.fromJson(r.data!);
  }

  Future<void> deleteMessage(String conversationId, String messageId) async {
    await _dio.delete<void>(
      '/conversations/$conversationId/messages/$messageId',
    );
  }

  /// Advance the caller's read marker to [upToSeq] (monotonic server-side).
  Future<void> markConversationRead(String conversationId, int upToSeq) async {
    await _dio.post<void>(
      '/conversations/$conversationId/read',
      data: {'up_to_seq': upToSeq},
    );
  }

  // ---- manager: who can I chat with ----

  /// Returns the studio's students for staff to start a dm / build a group.
  /// Reuses the existing admin students endpoint.
  Future<List<AdminStudentSummary>> chatableStudents({String? query}) async {
    final list = await adminListStudents(query: query);
    return list.students;
  }

  /// Returns the assigned 1-based waitlist position.
  Future<int> joinWaitlist(String classId) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/classes/$classId/waitlist',
    );
    return r.data!['position'] as int;
  }

  /// Removes the caller's queue entry for this class. Idempotent — leaving
  /// twice returns success.
  Future<void> leaveWaitlist(String classId) async {
    await _dio.delete<void>('/classes/$classId/waitlist');
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
    return r.data!.cast<Map<String, dynamic>>().map(ClassRow.fromJson).toList();
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

  /// Eligible passes for a *given student* against a class. Mirrors the
  /// student-self [eligibleEntitlements] but takes user_id so the manager
  /// picker can build a per-student dropdown.
  Future<List<EligibleEntitlement>> adminEligibleEntitlements({
    required String classId,
    required String userId,
  }) async {
    final r = await _dio.get<List<dynamic>>(
      '/admin/classes/$classId/eligible-entitlements',
      queryParameters: {'user_id': userId},
    );
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(EligibleEntitlement.fromJson)
        .toList();
  }

  /// Manager-side "Add student to class". Returns the new booking id.
  /// Throws an [ApiError] on conflicts (class full, already booked,
  /// entitlement ineligible, no credits) so callers can show the
  /// surfaced message verbatim.
  Future<String> adminCreateBooking({
    required String classId,
    required String userId,
    required String entitlementId,
    bool plusOne = false,
    String? plusOneName,
  }) async {
    final body = <String, dynamic>{
      'user_id': userId,
      'entitlement_id': entitlementId,
    };
    if (plusOne) {
      body['plus_one'] = true;
      body['plus_one_name'] = plusOneName ?? '';
    }
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/classes/$classId/bookings',
      data: body,
    );
    return r.data!['booking_id'] as String;
  }

  /// Manager-side "Remove from class". refundCredit=true puts the
  /// credit(s) back; false leaves the pass consumed.
  Future<Map<String, dynamic>> adminCancelBooking({
    required String bookingId,
    required bool refundCredit,
    String? reason,
  }) async {
    final body = <String, dynamic>{'refund_credit': refundCredit};
    if (reason != null && reason.isNotEmpty) body['reason'] = reason;
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/bookings/$bookingId/cancel',
      data: body,
    );
    return r.data!;
  }

  /// Resolves a single-use booking token and marks that booking attended.
  /// The token identifies the booking by itself — no class_id needed. Throws
  /// [ScanConflict] on a typed refusal (invalid_token, was_cancelled,
  /// outside_checkin_window).
  Future<ScanResult> adminCheckinScan({required String token}) async {
    try {
      final r = await _dio.post<Map<String, dynamic>>(
        '/admin/checkin/scan',
        data: {'token': token},
      );
      return ScanResult.fromJson(r.data!);
    } on DioException catch (e) {
      final status = e.response?.statusCode ?? 0;
      if (status == 404 || status == 409) {
        final base = ApiError.fromDio(e);
        throw ScanConflict(
          code: base.code,
          message: base.message,
          status: base.status,
          debug: base.debug,
        );
      }
      rethrow;
    }
  }

  // ---- themes + studio settings ----

  Future<List<ThemeRow>> adminListThemes() async {
    final r = await _dio.get<List<dynamic>>('/admin/themes');
    return r.data!.cast<Map<String, dynamic>>().map(ThemeRow.fromJson).toList();
  }

  Future<void> adminUpdateThemeTokens({
    required String themeId,
    required Map<String, String> tokens,
  }) async {
    await _dio.patch<void>('/admin/themes/$themeId', data: {'tokens': tokens});
  }

  /// Activate [themeId] into the studio's [slot] (`light` or `dark`). The
  /// server enforces that the theme's own mode matches the slot — passing
  /// a light theme into the dark slot returns `theme_mode_mismatch`.
  Future<void> adminActivateTheme(
    String themeId, {
    String slot = 'light',
  }) async {
    await _dio.post<void>(
      '/admin/themes/$themeId/activate',
      queryParameters: {'slot': slot},
    );
  }

  /// Persist the user's light/dark/system preference. Called from the
  /// Profile screen's theme toggle.
  Future<void> setMyThemeMode(ThemeModePref pref) async {
    await _dio.patch<void>(
      '/me/prefs',
      data: {'theme_mode_pref': themeModePrefToWire(pref)},
    );
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

  Future<void> adminUpdateProduct(String id, Map<String, dynamic> patch) async {
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

  Future<String> adminCreateRoom(String name, {String? color}) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/rooms',
      data: {
        'name': name,
        if (color != null) 'color': color,
      },
    );
    return r.data!['id'] as String;
  }

  /// Patch a room. Pass [name] or [color] (or both) to mutate; omitted
  /// fields are left untouched server-side. To clear an existing colour
  /// pass `color: ''` — distinct from omitting the field, which would
  /// preserve the current value. Use [adminUpdateRoom] now over the
  /// older `adminRenameRoom` shorthand.
  Future<void> adminUpdateRoom(
    String id, {
    String? name,
    String? color,
  }) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (color != null) body['color'] = color;
    await _dio.patch<void>('/admin/rooms/$id', data: body);
  }

  /// Thin wrapper for the name-only path. Older code uses it; new
  /// callers should go through [adminUpdateRoom] directly so the colour
  /// is editable from the same site.
  Future<void> adminRenameRoom(String id, String name) =>
      adminUpdateRoom(id, name: name);

  /// Deletes [id]. Throws [RoomInUseException] when the server refuses
  /// because the room is still referenced by classes / rules / templates
  /// — the UI surfaces that as a specific "move classes first" message
  /// rather than a generic delete failure.
  Future<void> adminDeleteRoom(String id) async {
    try {
      await _dio.delete<void>('/admin/rooms/$id');
    } on DioException catch (e) {
      final data = e.response?.data;
      if (e.response?.statusCode == 409 &&
          data is Map &&
          data['code'] == 'room_in_use') {
        final base = ApiError.fromDio(e);
        throw RoomInUseException(message: base.message, debug: base.debug);
      }
      rethrow;
    }
  }

  /// Create a class. With a `recurrence` block on the body the response is
  /// `{rule_id, generated_class_ids: [...], sessions: [...]}`; without it,
  /// `{id: ...}`. The raw map is returned so callers can branch.
  Future<Map<String, dynamic>> adminCreateClass(
    Map<String, dynamic> body,
  ) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/classes',
      data: body,
    );
    return r.data!;
  }

  /// Cancel a class. When [scope] is set on a rule-backed class the server
  /// cancels the matching range (`this` / `future` / `all`) and the response
  /// shape changes — we wrap both shapes in CancelClassResult.
  Future<CancelClassResult> adminCancelClass(String id, {String? scope}) async {
    final qp = scope == null || scope == 'this'
        ? null
        : <String, dynamic>{'scope': scope};
    final r = await _dio.delete<Map<String, dynamic>>(
      '/admin/classes/$id',
      queryParameters: qp,
    );
    return CancelClassResult.fromJson(r.data!);
  }

  /// Patch a class with optional scope. `null` and `this` both mean "single
  /// class only" (no scope query param), while `future` / `all` cascade to
  /// the rule's siblings.
  Future<void> adminPatchClass(
    String id,
    Map<String, dynamic> body, {
    String? scope,
  }) async {
    final qp = scope == null || scope == 'this'
        ? null
        : <String, dynamic>{'scope': scope};
    await _dio.patch<void>(
      '/admin/classes/$id',
      data: body,
      queryParameters: qp,
    );
  }

  Future<ClassTemplate> adminCreateClassTemplate(
    Map<String, dynamic> body,
  ) async {
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
      queryParameters: action == null || action == 'all'
          ? null
          : {'action': action},
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

  /// [to] is exclusive. Omitting the range falls back to the server's default
  /// window (current month + last 12 weeks).
  Future<RevenueReport> revenueReport({
    DateTime? from,
    DateTime? to,
    String? granularity,
  }) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/admin/reports/revenue',
      queryParameters: _rangeParams(from, to, granularity),
    );
    return RevenueReport.fromJson(r.data!);
  }

  Future<AttendanceReport> attendanceReport({
    DateTime? from,
    DateTime? to,
  }) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/admin/reports/attendance',
      queryParameters: _rangeParams(from, to, null),
    );
    return AttendanceReport.fromJson(r.data!);
  }

  Future<InstructorPayReport> instructorPayReport({
    DateTime? from,
    DateTime? to,
  }) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/admin/reports/instructor-pay',
      queryParameters: _rangeParams(from, to, null),
    );
    return InstructorPayReport.fromJson(r.data!);
  }

  Future<CustomerReport> customerReport({
    DateTime? from,
    DateTime? to,
    String? sort,
    String? q,
  }) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/admin/reports/customers',
      queryParameters: {
        if (from != null) 'from': _ymd(from),
        if (to != null) 'to': _ymd(to),
        if (sort != null) 'sort': sort,
        if (q != null && q.isNotEmpty) 'q': q,
      },
    );
    return CustomerReport.fromJson(r.data!);
  }

  /// Available datasets/columns/filters for the whitelisted report builder.
  Future<List<BuilderDataset>> builderSchema() async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/admin/reports/builder/schema',
    );
    return ((r.data!['datasets'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(BuilderDataset.fromJson)
        .toList();
  }

  Future<BuilderResult> runBuilder(Map<String, dynamic> spec) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/reports/builder/run',
      data: spec,
    );
    return BuilderResult.fromJson(r.data!);
  }

  Future<List<int>> runBuilderCsv(Map<String, dynamic> spec) async {
    final r = await _dio.post<List<int>>(
      '/admin/reports/builder/run',
      data: spec,
      queryParameters: {'format': 'csv'},
      options: Options(responseType: ResponseType.bytes),
    );
    return r.data!;
  }

  /// Fetches a report endpoint as raw CSV bytes (sends the bearer token via the
  /// interceptor, so the caller can't just open the URL). [reportPath] is e.g.
  /// '/admin/reports/revenue'.
  Future<List<int>> reportCsv(
    String reportPath, {
    DateTime? from,
    DateTime? to,
    String? granularity,
    String? sort,
    String? q,
  }) async {
    final r = await _dio.get<List<int>>(
      reportPath,
      queryParameters: {
        'format': 'csv',
        if (from != null) 'from': _ymd(from),
        if (to != null) 'to': _ymd(to),
        if (granularity != null) 'granularity': granularity,
        if (sort != null) 'sort': sort,
        if (q != null && q.isNotEmpty) 'q': q,
      },
      options: Options(responseType: ResponseType.bytes),
    );
    return r.data!;
  }

  static Map<String, dynamic>? _rangeParams(
    DateTime? from,
    DateTime? to,
    String? granularity,
  ) {
    if (from == null || to == null) return null;
    return {
      'from': _ymd(from),
      'to': _ymd(to),
      if (granularity != null) 'granularity': granularity,
    };
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

  /// Student notes — staff-visible free-text context attached to a
  /// student. Server scopes everything by studio_id so cross-tenant
  /// reads are impossible; author-only edit + delete enforced
  /// server-side (returns `not_message_sender` for someone else's note).

  Future<List<StudentNote>> adminListStudentNotes(String studentId) async {
    final r = await _dio.get<List<dynamic>>(
      '/admin/students/$studentId/notes',
    );
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(StudentNote.fromJson)
        .toList();
  }

  Future<String> adminCreateStudentNote({
    required String studentId,
    required String body,
  }) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/students/$studentId/notes',
      data: {'body': body},
    );
    return r.data!['id'] as String;
  }

  Future<void> adminUpdateStudentNote({
    required String noteId,
    required String body,
  }) async {
    await _dio.patch<void>('/admin/notes/$noteId', data: {'body': body});
  }

  Future<void> adminDeleteStudentNote(String noteId) async {
    await _dio.delete<void>('/admin/notes/$noteId');
  }

  /// UK GDPR Art. 15/20 subject-access export. Returns the raw JSON bundle so
  /// the caller can hand the encoded bytes to the platform download helper.
  Future<Map<String, dynamic>> adminExportStudent(String id) async {
    final r = await _dio.get<Map<String, dynamic>>(
      '/admin/students/$id/export',
    );
    return r.data!;
  }

  /// UK GDPR Art. 17 erasure. Pseudonymises the student server-side and
  /// deletes their auth account; the row is retained (tombstoned) so financial
  /// and audit records stay intact. Irreversible.
  Future<void> adminEraseStudent(String id) async {
    await _dio.delete<void>('/admin/students/$id');
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

  Future<List<AdminDiscount>> adminListDiscounts({
    bool includeArchived = false,
  }) async {
    final r = await _dio.get<List<dynamic>>(
      '/admin/discounts',
      queryParameters: {if (includeArchived) 'include_archived': '1'},
    );
    return r.data!
        .cast<Map<String, dynamic>>()
        .map(AdminDiscount.fromJson)
        .toList();
  }

  Future<AdminDiscount> adminCreateDiscount({
    String? code,
    required String kind,
    required int value,
    String? appliesToProductId,
    DateTime? validFrom,
    DateTime? validTo,
    int? maxUses,
    int? maxUsesPerUser,
    String notes = '',
  }) async {
    final r = await _dio.post<Map<String, dynamic>>(
      '/admin/discounts',
      data: {
        if (code != null && code.isNotEmpty) 'code': code,
        'kind': kind,
        'value': value,
        if (appliesToProductId != null && appliesToProductId.isNotEmpty)
          'applies_to_product_id': appliesToProductId,
        if (validFrom != null)
          'valid_from': validFrom.toUtc().toIso8601String(),
        if (validTo != null) 'valid_to': validTo.toUtc().toIso8601String(),
        if (maxUses != null) 'max_uses': maxUses,
        if (maxUsesPerUser != null) 'max_uses_per_user': maxUsesPerUser,
        if (notes.isNotEmpty) 'notes': notes,
      },
    );
    return AdminDiscount.fromJson(r.data!);
  }

  Future<void> adminArchiveDiscount(String id) async {
    await _dio.delete<void>('/admin/discounts/$id');
  }

  Future<void> adminRefundPurchase({
    required String purchaseId,
    required int refundAmountMinor,
    String note = '',
  }) async {
    await _dio.post<void>(
      '/admin/purchases/$purchaseId/refund',
      data: {
        'refund_amount_minor': refundAmountMinor,
        if (note.isNotEmpty) 'note': note,
      },
    );
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
    String? timezone,
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
    if (timezone != null) body['timezone'] = timezone;
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
              err.requestOptions..headers['Authorization'] = 'Bearer $fresh',
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
  // Gate on Firebase auth state so we don't hit auth-protected endpoints
  // before sign-in completes (and so we re-fetch when the user changes).
  final userAsync = ref.watch(firebaseUserProvider);
  if (userAsync.isLoading || userAsync.asData?.value == null) {
    // No auth token yet — stay in the "loading" state. The sign-in screen
    // is rendered upstream when the user is null, and once sign-in lands
    // this provider rebuilds and the real fetch fires.
    return Completer<Bootstrap>().future;
  }
  final api = ref.read(apiClientProvider);
  final results = await Future.wait([api.studioConfig(), api.me()]);
  return Bootstrap(results[0] as StudioConfig, results[1] as Me);
});

/// Live theme-mode preference. Seeded from the bootstrap's [Me.themeModePref]
/// the first time it's read, then driven by the Profile toggle. Optimistic:
/// the notifier updates state before awaiting the server, so the app re-themes
/// instantly and rolls back if the PATCH fails.
class ThemeModePrefNotifier extends Notifier<ThemeModePref> {
  @override
  ThemeModePref build() {
    // Seed from bootstrap if it's already resolved. Otherwise default to
    // light (matches the schema default) and let the first build() that
    // finds a real bootstrap value override.
    final boot = ref.watch(bootstrapProvider);
    return boot.asData?.value.me.themeModePref ?? ThemeModePref.light;
  }

  Future<void> set(ThemeModePref next) async {
    final prev = state;
    if (prev == next) return;
    state = next;
    try {
      await ref.read(apiClientProvider).setMyThemeMode(next);
    } catch (_) {
      state = prev;
      rethrow;
    }
  }
}

final themeModePrefProvider =
    NotifierProvider<ThemeModePrefNotifier, ThemeModePref>(
      ThemeModePrefNotifier.new,
    );

/// Typed booking-refusal error. Extends [ApiError] so it carries the
/// same `code` / `message` / `debug` payload as any other API error —
/// existing `on BookingConflict catch (e)` blocks keep working AND the
/// dev debug chip lights up automatically when the server is in
/// verbose mode.
class BookingConflict extends ApiError {
  BookingConflict({
    required super.code,
    required super.message,
    super.status,
    super.debug,
  });
}

class ScanConflict extends ApiError {
  ScanConflict({
    required super.code,
    required super.message,
    super.status,
    super.debug,
  });
}

/// Thrown by [ApiClient.adminDeleteRoom] when the server rejects the
/// delete with `room_in_use`. Inherits the standard ApiError shape so
/// the snackbar / inline display helpers work without a special case.
class RoomInUseException extends ApiError {
  RoomInUseException({required super.message, super.debug})
    : super(code: 'room_in_use', status: 409);
}

// Plain Dart models for the API responses we consume right now.
// Add fields/models as endpoints come online.

class StudioConfig {
  final String id;
  final String name;
  final String timezone;
  final String currency;
  final int freeCancelCutoffHours;
  final bool allowStudentPlusOne;
  final String welcomeMessage;
  final String buyLayout; // grid|list|grouped
  final String activeThemeId;
  final String activeThemeName;
  final String activeThemeMode; // light|dark
  final Map<String, dynamic> activeThemeTokens;
  final String? activeThemeSplashImage;

  StudioConfig({
    required this.id,
    required this.name,
    required this.timezone,
    required this.currency,
    required this.freeCancelCutoffHours,
    required this.allowStudentPlusOne,
    required this.welcomeMessage,
    required this.buyLayout,
    required this.activeThemeId,
    required this.activeThemeName,
    required this.activeThemeMode,
    required this.activeThemeTokens,
    required this.activeThemeSplashImage,
  });

  factory StudioConfig.fromJson(Map<String, dynamic> j) => StudioConfig(
        id: j['id'] as String,
        name: j['name'] as String,
        timezone: j['timezone'] as String,
        currency: j['currency'] as String,
        freeCancelCutoffHours: j['free_cancel_cutoff_hours'] as int,
        allowStudentPlusOne: j['allow_student_plus_one'] as bool,
        welcomeMessage: j['welcome_message'] as String,
        buyLayout: j['buy_layout'] as String,
        activeThemeId: j['active_theme_id'] as String,
        activeThemeName: j['active_theme_name'] as String,
        activeThemeMode: j['active_theme_mode'] as String,
        activeThemeTokens:
            Map<String, dynamic>.from(j['active_theme_tokens'] as Map),
        activeThemeSplashImage: j['active_theme_splash_image'] as String?,
      );
}

/// Access tier — what the caller can reach in the admin console. Derived
/// server-side from `role` and returned alongside it on /me. Single source
/// of truth lives in api.go's `tierForRole` and the requireStaff/Manager
/// middlewares.
enum AccessTier { student, staff, manager }

AccessTier _parseTier(String? raw) => switch (raw) {
      'manager' => AccessTier.manager,
      'staff' => AccessTier.staff,
      _ => AccessTier.student,
    };

class Me {
  final String id;
  final String studioId;
  final String role;
  final String email;
  final String fullName;
  final String? photoUrl;
  final AccessTier tier;

  Me({
    required this.id,
    required this.studioId,
    required this.role,
    required this.email,
    required this.fullName,
    required this.photoUrl,
    required this.tier,
  });

  factory Me.fromJson(Map<String, dynamic> j) => Me(
        id: j['id'] as String,
        studioId: j['studio_id'] as String,
        role: j['role'] as String,
        email: j['email'] as String,
        fullName: j['full_name'] as String,
        photoUrl: j['photo_url'] as String?,
        tier: _parseTier(j['tier'] as String?),
      );

  String get firstName => fullName.split(' ').first;

  bool get isManager => tier == AccessTier.manager;
  bool get isStaff => tier == AccessTier.staff || tier == AccessTier.manager;
}

enum BookingState { booked, available, full }

class ClassRow {
  final String id;
  final String title;
  final String classTypeName;
  final String discipline;
  final String instructorId;
  final String instructorName;
  final String? instructorPhotoUrl;
  final String roomName;
  final DateTime startsAt;
  final DateTime endsAt;
  final int durationMinutes;
  final int capacity;
  final int bookedCount;
  final BookingState bookingState;
  final String? bookingId;

  ClassRow({
    required this.id,
    required this.title,
    required this.classTypeName,
    required this.discipline,
    required this.instructorId,
    required this.instructorName,
    required this.instructorPhotoUrl,
    required this.roomName,
    required this.startsAt,
    required this.endsAt,
    required this.durationMinutes,
    required this.capacity,
    required this.bookedCount,
    required this.bookingState,
    required this.bookingId,
  });

  factory ClassRow.fromJson(Map<String, dynamic> j) => ClassRow(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? '',
        classTypeName: j['class_type_name'] as String,
        discipline: j['discipline'] as String,
        instructorId: j['instructor_id'] as String,
        instructorName: j['instructor_name'] as String,
        instructorPhotoUrl: j['instructor_photo_url'] as String?,
        roomName: j['room_name'] as String,
        startsAt: DateTime.parse(j['starts_at'] as String),
        endsAt: DateTime.parse(j['ends_at'] as String),
        durationMinutes: j['duration_minutes'] as int,
        capacity: j['capacity'] as int,
        bookedCount: j['booked_count'] as int,
        bookingState: switch (j['booking_state'] as String) {
          'booked' => BookingState.booked,
          'full' => BookingState.full,
          _ => BookingState.available,
        },
        bookingId: j['booking_id'] as String?,
      );

  int get spotsLeft => capacity - bookedCount;
}

class ClassDetail {
  final ClassRow row;
  final int waitlistCount;

  ClassDetail({required this.row, required this.waitlistCount});

  factory ClassDetail.fromJson(Map<String, dynamic> j) => ClassDetail(
        row: ClassRow.fromJson(j),
        waitlistCount: (j['waitlist_count'] as int?) ?? 0,
      );
}

class EligibleEntitlement {
  final String id;
  final String label;
  final String passKind; // unlimited | credit
  final int? creditsRemaining;
  final DateTime? expiresAt;

  EligibleEntitlement({
    required this.id,
    required this.label,
    required this.passKind,
    required this.creditsRemaining,
    required this.expiresAt,
  });

  factory EligibleEntitlement.fromJson(Map<String, dynamic> j) =>
      EligibleEntitlement(
        id: j['id'] as String,
        label: j['label'] as String,
        passKind: j['pass_kind'] as String,
        creditsRemaining: j['credits_remaining'] as int?,
        expiresAt: (j['expires_at'] as String?)?.let(DateTime.tryParse),
      );
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

class Product {
  final String id;
  final String name;
  final String description;
  final int priceMinor;
  final String currency;
  final String billingType; // one_time | recurring
  final String passKind; // credit | unlimited
  final int? credits;
  final int? validityDays;
  final bool isHero;
  final List<String> classTypeIds;
  final List<String> disciplines;

  Product({
    required this.id,
    required this.name,
    required this.description,
    required this.priceMinor,
    required this.currency,
    required this.billingType,
    required this.passKind,
    required this.credits,
    required this.validityDays,
    required this.isHero,
    required this.classTypeIds,
    required this.disciplines,
  });

  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: j['id'] as String,
        name: j['name'] as String,
        description: (j['description'] as String?) ?? '',
        priceMinor: j['price_minor'] as int,
        currency: j['currency'] as String,
        billingType: j['billing_type'] as String,
        passKind: j['pass_kind'] as String,
        credits: j['credits'] as int?,
        validityDays: j['validity_days'] as int?,
        isHero: j['is_hero'] as bool,
        classTypeIds:
            ((j['class_type_ids'] as List?) ?? const []).cast<String>(),
        disciplines:
            ((j['disciplines'] as List?) ?? const []).cast<String>(),
      );

  bool get isMembership => billingType == 'recurring' || passKind == 'unlimited';

  String formattedPrice() {
    final symbol = switch (currency) {
      'GBP' => '£',
      'USD' => '\$',
      'EUR' => '€',
      _ => '$currency ',
    };
    final whole = priceMinor ~/ 100;
    final cents = priceMinor % 100;
    final body = cents == 0 ? '$whole' : '$whole.${cents.toString().padLeft(2, '0')}';
    return '$symbol$body';
  }

  /// "All yoga", "Reformer only", "All disciplines"...
  String gateLabel() {
    if (disciplines.length >= 2) return 'All disciplines';
    if (disciplines.length == 1) {
      final d = disciplines.first;
      if (d == 'yoga') return 'All yoga';
      return '${_cap(d)} only';
    }
    return '';
  }

  bool get gateIsAccent => disciplines.length == 1 && disciplines.first != 'yoga';

  String terms() {
    final parts = <String>[];
    if (passKind == 'credit' && credits != null) {
      parts.add('$credits credit${credits == 1 ? '' : 's'}');
    } else {
      parts.add('Unlimited');
    }
    if (validityDays != null) {
      parts.add('valid ${validityDays!} days');
    }
    final gate = gateLabel();
    if (gate.isNotEmpty) parts.insert(1, gate.toLowerCase());
    return parts.join(' · ');
  }

  static String _cap(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

class PurchaseResult {
  final String purchaseId;
  final PurchaseEntitlement entitlement;
  PurchaseResult({required this.purchaseId, required this.entitlement});

  factory PurchaseResult.fromJson(Map<String, dynamic> j) => PurchaseResult(
        purchaseId: j['purchase_id'] as String,
        entitlement: PurchaseEntitlement.fromJson(
            j['entitlement'] as Map<String, dynamic>),
      );
}

class PurchaseEntitlement {
  final String id;
  final String label;
  final String passKind;
  final int? creditsTotal;
  final int? creditsRemaining;
  final DateTime? expiresAt;

  PurchaseEntitlement({
    required this.id,
    required this.label,
    required this.passKind,
    required this.creditsTotal,
    required this.creditsRemaining,
    required this.expiresAt,
  });

  factory PurchaseEntitlement.fromJson(Map<String, dynamic> j) =>
      PurchaseEntitlement(
        id: j['id'] as String,
        label: j['label'] as String,
        passKind: j['pass_kind'] as String,
        creditsTotal: j['credits_total'] as int?,
        creditsRemaining: j['credits_remaining'] as int?,
        expiresAt: (j['expires_at'] as String?)?.let(DateTime.tryParse),
      );
}

class AdminInstructor {
  final String id;
  final String fullName;
  AdminInstructor({required this.id, required this.fullName});
  factory AdminInstructor.fromJson(Map<String, dynamic> j) => AdminInstructor(
        id: j['id'] as String,
        fullName: j['full_name'] as String,
      );
}

class AdminRoom {
  final String id;
  final String name;
  AdminRoom({required this.id, required this.name});
  factory AdminRoom.fromJson(Map<String, dynamic> j) => AdminRoom(
        id: j['id'] as String,
        name: j['name'] as String,
      );
}

class CancelClassResult {
  final int bookingsCancelled;
  final int creditsReturned;
  final int notificationsSent;
  final int waitlistCleared;
  CancelClassResult({
    required this.bookingsCancelled,
    required this.creditsReturned,
    required this.notificationsSent,
    required this.waitlistCleared,
  });
  factory CancelClassResult.fromJson(Map<String, dynamic> j) => CancelClassResult(
        bookingsCancelled: j['bookings_cancelled'] as int,
        creditsReturned: j['credits_returned'] as int,
        notificationsSent: j['notifications_sent'] as int,
        waitlistCleared: j['waitlist_cleared'] as int,
      );
}

class ClassTemplate {
  final String id;
  final String title;
  final String status; // active | reverted
  final List<String> generatedClassIds;
  final List<String> sessions;
  final DateTime createdAt;
  ClassTemplate({
    required this.id,
    required this.title,
    required this.status,
    required this.generatedClassIds,
    required this.sessions,
    required this.createdAt,
  });
  factory ClassTemplate.fromJson(Map<String, dynamic> j) => ClassTemplate(
        id: j['id'] as String,
        title: j['title'] as String,
        status: j['status'] as String,
        generatedClassIds:
            ((j['generated_class_ids'] as List?) ?? const []).cast<String>(),
        sessions: ((j['sessions'] as List?) ?? const []).cast<String>(),
        createdAt: DateTime.parse(j['created_at'] as String),
      );
}

class UndoTemplateResult {
  final int totalClasses;
  final CancelClassResult summary;
  UndoTemplateResult({required this.totalClasses, required this.summary});
  factory UndoTemplateResult.fromJson(Map<String, dynamic> j) =>
      UndoTemplateResult(
        totalClasses: j['total_classes'] as int,
        summary: CancelClassResult.fromJson(
            (j['summary'] as Map).cast<String, dynamic>()),
      );
}

class AuditEntry {
  final String id;
  final String actorId;
  final String actorName;
  final String action;
  final String targetType;
  final String targetId;
  final Map<String, dynamic> detail;
  final DateTime createdAt;

  AuditEntry({
    required this.id,
    required this.actorId,
    required this.actorName,
    required this.action,
    required this.targetType,
    required this.targetId,
    required this.detail,
    required this.createdAt,
  });

  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
        id: j['id'] as String,
        actorId: j['actor_id'] as String,
        actorName: j['actor_name'] as String,
        action: j['action'] as String,
        targetType: j['target_type'] as String,
        targetId: (j['target_id'] as String?) ?? '',
        detail: Map<String, dynamic>.from((j['detail'] as Map?) ?? {}),
        createdAt: DateTime.parse(j['created_at'] as String),
      );
}

class EnrollmentSummary {
  final String id;
  final String title;
  final String description;
  final int sessionCount;
  final int capacity;
  final int enrolledCount;
  final int priceMinor;
  final String currency;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final String instructorName;
  final String seriesState; // open | full | enrolled

  EnrollmentSummary({
    required this.id,
    required this.title,
    required this.description,
    required this.sessionCount,
    required this.capacity,
    required this.enrolledCount,
    required this.priceMinor,
    required this.currency,
    required this.startsAt,
    required this.endsAt,
    required this.instructorName,
    required this.seriesState,
  });

  factory EnrollmentSummary.fromJson(Map<String, dynamic> j) => EnrollmentSummary(
        id: j['id'] as String,
        title: j['title'] as String,
        description: (j['description'] as String?) ?? '',
        sessionCount: j['session_count'] as int,
        capacity: j['capacity'] as int,
        enrolledCount: j['enrolled_count'] as int,
        priceMinor: j['price_minor'] as int,
        currency: j['currency'] as String,
        startsAt: _parseDate(j['starts_at']),
        endsAt: _parseDate(j['ends_at']),
        instructorName: (j['instructor_name'] as String?) ?? '',
        seriesState: j['series_state'] as String,
      );

  int get seatsLeft => capacity - enrolledCount;

  String formattedPrice() {
    final symbol = switch (currency) {
      'GBP' => '£',
      'USD' => '\$',
      'EUR' => '€',
      _ => '$currency ',
    };
    final whole = priceMinor ~/ 100;
    final cents = priceMinor % 100;
    final body =
        cents == 0 ? '$whole' : '$whole.${cents.toString().padLeft(2, '0')}';
    return '$symbol$body';
  }

  static DateTime? _parseDate(dynamic v) {
    if (v is! String || v.isEmpty) return null;
    return DateTime.tryParse(v);
  }
}

class AdminEnrollmentSummary {
  final EnrollmentSummary summary;
  final int revenueMinor;
  final int attendancePct;
  final int upcomingSessions;
  AdminEnrollmentSummary({
    required this.summary,
    required this.revenueMinor,
    required this.attendancePct,
    required this.upcomingSessions,
  });
  factory AdminEnrollmentSummary.fromJson(Map<String, dynamic> j) =>
      AdminEnrollmentSummary(
        summary: EnrollmentSummary.fromJson(j),
        revenueMinor: (j['revenue_minor'] as int?) ?? 0,
        attendancePct: (j['attendance_pct'] as int?) ?? 0,
        upcomingSessions: (j['upcoming_sessions'] as int?) ?? 0,
      );
}

class SeriesRoster {
  final EnrollmentSummary series;
  final List<EnrollmentSession> sessions;
  final int currentWeekIdx;
  final List<SeriesRosterStudent> students;
  SeriesRoster({
    required this.series,
    required this.sessions,
    required this.currentWeekIdx,
    required this.students,
  });
  factory SeriesRoster.fromJson(Map<String, dynamic> j) => SeriesRoster(
        series: EnrollmentSummary.fromJson(
            (j['series'] as Map).cast<String, dynamic>()),
        sessions: ((j['sessions'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(EnrollmentSession.fromJson)
            .toList(),
        currentWeekIdx: (j['current_week_idx'] as int?) ?? 0,
        students: ((j['students'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(SeriesRosterStudent.fromJson)
            .toList(),
      );
}

class SeriesRosterStudent {
  final String userId;
  final String fullName;
  final List<String> cells; // present | no_show | upcoming | unmarked | absent
  SeriesRosterStudent({
    required this.userId,
    required this.fullName,
    required this.cells,
  });
  factory SeriesRosterStudent.fromJson(Map<String, dynamic> j) =>
      SeriesRosterStudent(
        userId: j['user_id'] as String,
        fullName: j['full_name'] as String,
        cells: ((j['cells'] as List?) ?? const []).cast<String>(),
      );
}

class EnrollmentSession {
  final String id;
  final int weekIdx;
  final DateTime startsAt;
  final DateTime endsAt;
  final String roomName;
  EnrollmentSession({
    required this.id,
    required this.weekIdx,
    required this.startsAt,
    required this.endsAt,
    required this.roomName,
  });
  factory EnrollmentSession.fromJson(Map<String, dynamic> j) => EnrollmentSession(
        id: j['id'] as String,
        weekIdx: j['week_idx'] as int,
        startsAt: DateTime.parse(j['starts_at'] as String),
        endsAt: DateTime.parse(j['ends_at'] as String),
        roomName: j['room_name'] as String,
      );
}

class EnrollmentDetail {
  final EnrollmentSummary summary;
  final List<EnrollmentSession> sessions;
  EnrollmentDetail({required this.summary, required this.sessions});
  factory EnrollmentDetail.fromJson(Map<String, dynamic> j) => EnrollmentDetail(
        summary: EnrollmentSummary.fromJson(j),
        sessions: ((j['sessions'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(EnrollmentSession.fromJson)
            .toList(),
      );
}

class AdminReports {
  final ReportMonthRevenue revenueMonth;
  final int avgOccupancyPct;
  final int noShowRatePct;
  final List<ReportWeekRevenue> revenueByWeek;
  final List<ReportInstructorPay> instructorPay;

  AdminReports({
    required this.revenueMonth,
    required this.avgOccupancyPct,
    required this.noShowRatePct,
    required this.revenueByWeek,
    required this.instructorPay,
  });

  factory AdminReports.fromJson(Map<String, dynamic> j) => AdminReports(
        revenueMonth: ReportMonthRevenue.fromJson(
            j['revenue_month'] as Map<String, dynamic>),
        avgOccupancyPct: j['avg_occupancy_pct'] as int,
        noShowRatePct: j['no_show_rate_pct'] as int,
        revenueByWeek: ((j['revenue_by_week'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(ReportWeekRevenue.fromJson)
            .toList(),
        instructorPay: ((j['instructor_pay'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(ReportInstructorPay.fromJson)
            .toList(),
      );
}

class ReportMonthRevenue {
  final int totalMinor;
  final int cardMinor;
  final int cashMinor;
  final String currency;
  final String monthLabel;
  ReportMonthRevenue({
    required this.totalMinor,
    required this.cardMinor,
    required this.cashMinor,
    required this.currency,
    required this.monthLabel,
  });
  factory ReportMonthRevenue.fromJson(Map<String, dynamic> j) =>
      ReportMonthRevenue(
        totalMinor: j['total_minor'] as int,
        cardMinor: j['card_minor'] as int,
        cashMinor: j['cash_minor'] as int,
        currency: j['currency'] as String,
        monthLabel: j['month_label'] as String,
      );
}

class ReportWeekRevenue {
  final String weekStart;
  final int cardMinor;
  final int cashMinor;
  ReportWeekRevenue({
    required this.weekStart,
    required this.cardMinor,
    required this.cashMinor,
  });
  factory ReportWeekRevenue.fromJson(Map<String, dynamic> j) => ReportWeekRevenue(
        weekStart: j['week_start'] as String,
        cardMinor: j['card_minor'] as int,
        cashMinor: j['cash_minor'] as int,
      );
  int get total => cardMinor + cashMinor;
}

class ReportInstructorPay {
  final String instructorId;
  final String fullName;
  final int classesTaught;
  final int payMinor;
  ReportInstructorPay({
    required this.instructorId,
    required this.fullName,
    required this.classesTaught,
    required this.payMinor,
  });
  factory ReportInstructorPay.fromJson(Map<String, dynamic> j) =>
      ReportInstructorPay(
        instructorId: j['instructor_id'] as String,
        fullName: j['full_name'] as String,
        classesTaught: j['classes_taught'] as int,
        payMinor: j['pay_minor'] as int,
      );
}

class AdminStudentSummary {
  final String id;
  final String fullName;
  final String email;
  final String? photoUrl;
  final String activePassLabel;
  final String activePassDetail;
  final bool hasActivePass;
  final DateTime? lastVisit;
  final DateTime createdAt;

  AdminStudentSummary({
    required this.id,
    required this.fullName,
    required this.email,
    required this.photoUrl,
    required this.activePassLabel,
    required this.activePassDetail,
    required this.hasActivePass,
    required this.lastVisit,
    required this.createdAt,
  });

  factory AdminStudentSummary.fromJson(Map<String, dynamic> j) =>
      AdminStudentSummary(
        id: j['id'] as String,
        fullName: j['full_name'] as String,
        email: j['email'] as String,
        photoUrl: j['photo_url'] as String?,
        activePassLabel: j['active_pass_label'] as String,
        activePassDetail: j['active_pass_detail'] as String,
        hasActivePass: j['has_active_pass'] as bool,
        lastVisit: (j['last_visit'] as String?)?.let(DateTime.tryParse),
        createdAt: DateTime.parse(j['created_at'] as String),
      );
}

class AdminStudentsList {
  final List<AdminStudentSummary> students;
  final int total;
  final int withActivePass;
  AdminStudentsList({
    required this.students,
    required this.total,
    required this.withActivePass,
  });
  factory AdminStudentsList.fromJson(Map<String, dynamic> j) {
    final c = j['counts'] as Map<String, dynamic>;
    return AdminStudentsList(
      students: ((j['students'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map(AdminStudentSummary.fromJson)
          .toList(),
      total: c['total'] as int,
      withActivePass: c['active_pass'] as int,
    );
  }
}

class AdminStudentDetail {
  final String id;
  final String fullName;
  final String email;
  final String? photoUrl;
  final DateTime createdAt;
  final List<WalletEntitlement> entitlements;
  final List<WalletPurchase> purchases;
  final List<UpcomingBooking> upcoming;

  AdminStudentDetail({
    required this.id,
    required this.fullName,
    required this.email,
    required this.photoUrl,
    required this.createdAt,
    required this.entitlements,
    required this.purchases,
    required this.upcoming,
  });

  factory AdminStudentDetail.fromJson(Map<String, dynamic> j) =>
      AdminStudentDetail(
        id: j['id'] as String,
        fullName: j['full_name'] as String,
        email: j['email'] as String,
        photoUrl: j['photo_url'] as String?,
        createdAt: DateTime.parse(j['created_at'] as String),
        entitlements: ((j['entitlements'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(WalletEntitlement.fromJson)
            .toList(),
        purchases: ((j['purchases'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(WalletPurchase.fromJson)
            .toList(),
        upcoming: ((j['upcoming'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(UpcomingBooking.fromJson)
            .toList(),
      );
}

class AdminProductUsage {
  final int activePasses;
  final int revenueMinor;
  final DateTime? lastSale;
  AdminProductUsage({
    required this.activePasses,
    required this.revenueMinor,
    required this.lastSale,
  });
  factory AdminProductUsage.fromJson(Map<String, dynamic> j) =>
      AdminProductUsage(
        activePasses: j['active_passes'] as int,
        revenueMinor: j['revenue_minor'] as int,
        lastSale: (j['last_sale'] as String?)?.let(DateTime.tryParse),
      );
}

class AdminProduct {
  final String id;
  final String name;
  final String description;
  final int priceMinor;
  final String currency;
  final String billingType;
  final String passKind;
  final int? credits;
  final int? validityDays;
  final bool isHero;
  final bool isArchived;
  final int displayOrder;
  final List<String> classTypeIds;
  final List<String> disciplines;
  final AdminProductUsage usage;

  AdminProduct({
    required this.id,
    required this.name,
    required this.description,
    required this.priceMinor,
    required this.currency,
    required this.billingType,
    required this.passKind,
    required this.credits,
    required this.validityDays,
    required this.isHero,
    required this.isArchived,
    required this.displayOrder,
    required this.classTypeIds,
    required this.disciplines,
    required this.usage,
  });

  factory AdminProduct.fromJson(Map<String, dynamic> j) => AdminProduct(
        id: j['id'] as String,
        name: j['name'] as String,
        description: (j['description'] as String?) ?? '',
        priceMinor: j['price_minor'] as int,
        currency: j['currency'] as String,
        billingType: j['billing_type'] as String,
        passKind: j['pass_kind'] as String,
        credits: j['credits'] as int?,
        validityDays: j['validity_days'] as int?,
        isHero: j['is_hero'] as bool,
        isArchived: j['is_archived'] as bool,
        displayOrder: j['display_order'] as int,
        classTypeIds:
            ((j['class_type_ids'] as List?) ?? const []).cast<String>(),
        disciplines:
            ((j['disciplines'] as List?) ?? const []).cast<String>(),
        usage: AdminProductUsage.fromJson(j['usage'] as Map<String, dynamic>),
      );

  bool get isMembership =>
      billingType == 'recurring' || passKind == 'unlimited';

  String formattedPrice() {
    final symbol = switch (currency) {
      'GBP' => '£',
      'USD' => '\$',
      'EUR' => '€',
      _ => '$currency ',
    };
    final whole = priceMinor ~/ 100;
    final cents = priceMinor % 100;
    final body =
        cents == 0 ? '$whole' : '$whole.${cents.toString().padLeft(2, '0')}';
    return '$symbol$body';
  }

  String gateLabel() {
    if (disciplines.length >= 2) return 'All disciplines';
    if (disciplines.length == 1) {
      final d = disciplines.first;
      if (d == 'yoga') return 'All yoga';
      return '${d[0].toUpperCase()}${d.substring(1)} only';
    }
    return '';
  }
}

class ClassType {
  final String id;
  final String name;
  final String discipline;
  ClassType({required this.id, required this.name, required this.discipline});
  factory ClassType.fromJson(Map<String, dynamic> j) => ClassType(
        id: j['id'] as String,
        name: j['name'] as String,
        discipline: (j['discipline'] as String?) ?? '',
      );
}

class ThemeRow {
  final String id;
  final String name;
  final bool isPreset;
  final String mode;
  final Map<String, String> tokens;
  final bool isActive;

  ThemeRow({
    required this.id,
    required this.name,
    required this.isPreset,
    required this.mode,
    required this.tokens,
    required this.isActive,
  });

  factory ThemeRow.fromJson(Map<String, dynamic> j) => ThemeRow(
        id: j['id'] as String,
        name: j['name'] as String,
        isPreset: j['is_preset'] as bool,
        mode: j['mode'] as String,
        tokens: Map<String, String>.from(
            (j['tokens'] as Map).map((k, v) => MapEntry(k as String, v as String))),
        isActive: j['is_active'] as bool,
      );

  ThemeRow copyWithTokens(Map<String, String> next) => ThemeRow(
        id: id,
        name: name,
        isPreset: isPreset,
        mode: mode,
        tokens: next,
        isActive: isActive,
      );
}

class Roster {
  final RosterClassHeader klass;
  final RosterCounts counts;
  final List<RosterBookingRow> booked;
  final List<RosterWaitlistRow> waitlist;

  Roster({
    required this.klass,
    required this.counts,
    required this.booked,
    required this.waitlist,
  });

  factory Roster.fromJson(Map<String, dynamic> j) => Roster(
        klass: RosterClassHeader.fromJson(j['class'] as Map<String, dynamic>),
        counts: RosterCounts.fromJson(j['counts'] as Map<String, dynamic>),
        booked: ((j['booked'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(RosterBookingRow.fromJson)
            .toList(),
        waitlist: ((j['waitlist'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(RosterWaitlistRow.fromJson)
            .toList(),
      );
}

class RosterClassHeader {
  final String id;
  final String title;
  final DateTime startsAt;
  final DateTime endsAt;
  final String roomName;
  final String instructorName;
  final int capacity;

  RosterClassHeader({
    required this.id,
    required this.title,
    required this.startsAt,
    required this.endsAt,
    required this.roomName,
    required this.instructorName,
    required this.capacity,
  });

  factory RosterClassHeader.fromJson(Map<String, dynamic> j) => RosterClassHeader(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? '',
        startsAt: DateTime.parse(j['starts_at'] as String),
        endsAt: DateTime.parse(j['ends_at'] as String),
        roomName: j['room_name'] as String,
        instructorName: j['instructor_name'] as String,
        capacity: j['capacity'] as int,
      );
}

class RosterCounts {
  final int booked;
  final int unmarked;
  final int present;
  final int noShow;
  RosterCounts({
    required this.booked,
    required this.unmarked,
    required this.present,
    required this.noShow,
  });
  factory RosterCounts.fromJson(Map<String, dynamic> j) => RosterCounts(
        booked: j['booked'] as int,
        unmarked: j['unmarked'] as int,
        present: j['present'] as int,
        noShow: j['no_show'] as int,
      );
}

class RosterBookingRow {
  final String bookingId;
  final String userId;
  final String fullName;
  final String? photoUrl;
  final String passLabel;
  final String status; // booked | attended | no_show
  final bool isPlusOne;
  final String? attendanceVia; // manual | scan

  RosterBookingRow({
    required this.bookingId,
    required this.userId,
    required this.fullName,
    required this.photoUrl,
    required this.passLabel,
    required this.status,
    required this.isPlusOne,
    required this.attendanceVia,
  });

  factory RosterBookingRow.fromJson(Map<String, dynamic> j) => RosterBookingRow(
        bookingId: j['booking_id'] as String,
        userId: j['user_id'] as String,
        fullName: j['full_name'] as String,
        photoUrl: j['photo_url'] as String?,
        passLabel: j['pass_label'] as String,
        status: j['status'] as String,
        isPlusOne: (j['is_plus_one'] as bool?) ?? false,
        attendanceVia: j['attendance_via'] as String?,
      );
}

class RosterWaitlistRow {
  final String userId;
  final String fullName;
  final int position;
  RosterWaitlistRow({
    required this.userId,
    required this.fullName,
    required this.position,
  });
  factory RosterWaitlistRow.fromJson(Map<String, dynamic> j) =>
      RosterWaitlistRow(
        userId: j['user_id'] as String,
        fullName: j['full_name'] as String,
        position: j['position'] as int,
      );
}

class PromoteResult {
  final String bookingId;
  final String promotedName;
  PromoteResult({required this.bookingId, required this.promotedName});
  factory PromoteResult.fromJson(Map<String, dynamic> j) => PromoteResult(
        bookingId: j['booking_id'] as String,
        promotedName: j['promoted_name'] as String,
      );
}

class AdminDashboard {
  final String date;
  final AdminOccupancy occupancyToday;
  final AdminRevenueToday revenueToday;
  final int newBookingsToday;
  final int unmarkedAttendance;
  final List<ClassRow> classesToday;

  AdminDashboard({
    required this.date,
    required this.occupancyToday,
    required this.revenueToday,
    required this.newBookingsToday,
    required this.unmarkedAttendance,
    required this.classesToday,
  });

  factory AdminDashboard.fromJson(Map<String, dynamic> j) => AdminDashboard(
        date: j['date'] as String,
        occupancyToday: AdminOccupancy.fromJson(
            j['occupancy_today'] as Map<String, dynamic>),
        revenueToday: AdminRevenueToday.fromJson(
            j['revenue_today'] as Map<String, dynamic>),
        newBookingsToday: j['new_bookings_today'] as int,
        unmarkedAttendance: j['unmarked_attendance_count'] as int,
        classesToday: ((j['classes_today'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(ClassRow.fromJson)
            .toList(),
      );
}

class AdminOccupancy {
  final int bookedSeats;
  final int totalCapacity;
  final int percent;
  AdminOccupancy({
    required this.bookedSeats,
    required this.totalCapacity,
    required this.percent,
  });
  factory AdminOccupancy.fromJson(Map<String, dynamic> j) => AdminOccupancy(
        bookedSeats: j['booked_seats'] as int,
        totalCapacity: j['total_capacity'] as int,
        percent: j['percent'] as int,
      );
}

class AdminRevenueToday {
  final int totalMinor;
  final int cardMinor;
  final int cashMinor;
  final String currency;
  AdminRevenueToday({
    required this.totalMinor,
    required this.cardMinor,
    required this.cashMinor,
    required this.currency,
  });
  factory AdminRevenueToday.fromJson(Map<String, dynamic> j) =>
      AdminRevenueToday(
        totalMinor: j['total_minor'] as int,
        cardMinor: j['card_minor'] as int,
        cashMinor: j['cash_minor'] as int,
        currency: j['currency'] as String,
      );

  String fmt(int minor) {
    final symbol = switch (currency) {
      'GBP' => '£',
      'USD' => '\$',
      'EUR' => '€',
      _ => '$currency ',
    };
    final whole = minor ~/ 100;
    final cents = minor % 100;
    final body = cents == 0 ? '$whole' : '$whole.${cents.toString().padLeft(2, '0')}';
    return '$symbol$body';
  }
}

class NotificationItem {
  final String id;
  final String type;
  final String title;
  final String body;
  final DateTime createdAt;
  final DateTime? readAt;

  NotificationItem({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.readAt,
  });

  factory NotificationItem.fromJson(Map<String, dynamic> j) => NotificationItem(
        id: j['id'] as String,
        type: j['type'] as String,
        title: j['title'] as String,
        body: (j['body'] as String?) ?? '',
        createdAt: DateTime.parse(j['created_at'] as String),
        readAt: (j['read_at'] as String?)?.let(DateTime.tryParse),
      );

  bool get unread => readAt == null;
}

class CheckInPayload {
  final String token;
  final String userName;
  final UpcomingBooking? nextClass;

  CheckInPayload({
    required this.token,
    required this.userName,
    required this.nextClass,
  });

  factory CheckInPayload.fromJson(Map<String, dynamic> j) => CheckInPayload(
        token: j['token'] as String,
        userName: j['user_name'] as String,
        nextClass: j['next_class'] == null
            ? null
            : UpcomingBooking.fromJson(
                j['next_class'] as Map<String, dynamic>),
      );
}

class WalletEntitlement {
  final String id;
  final String label;
  final String passKind; // unlimited | credit
  final String status; // active | expired | depleted | voided
  final int? creditsTotal;
  final int? creditsRemaining;
  final DateTime? expiresAt;
  final DateTime createdAt;
  final List<String> disciplines;

  WalletEntitlement({
    required this.id,
    required this.label,
    required this.passKind,
    required this.status,
    required this.creditsTotal,
    required this.creditsRemaining,
    required this.expiresAt,
    required this.createdAt,
    required this.disciplines,
  });

  factory WalletEntitlement.fromJson(Map<String, dynamic> j) => WalletEntitlement(
        id: j['id'] as String,
        label: j['label'] as String,
        passKind: j['pass_kind'] as String,
        status: j['status'] as String,
        creditsTotal: j['credits_total'] as int?,
        creditsRemaining: j['credits_remaining'] as int?,
        expiresAt: (j['expires_at'] as String?)?.let((s) =>
            s.isEmpty ? null : DateTime.tryParse(s)),
        createdAt: DateTime.parse(j['created_at'] as String),
        disciplines:
            ((j['disciplines'] as List?) ?? const []).cast<String>(),
      );

  bool get isActive => status == 'active';
  bool get isUnlimited => passKind == 'unlimited';

  /// "All yoga", "Reformer only", "All disciplines"...
  String gateLabel() {
    if (disciplines.length >= 2) return 'All disciplines';
    if (disciplines.length == 1) {
      final d = disciplines.first;
      if (d == 'yoga') return 'All yoga';
      return '${d[0].toUpperCase()}${d.substring(1)} only';
    }
    return '';
  }

  bool get gateIsAccent =>
      disciplines.length == 1 && disciplines.first != 'yoga';
}

class WalletPurchase {
  final String id;
  final String productName;
  final int amountMinor;
  final String currency;
  final String paymentMethod; // card | cash | dev_stub
  final String status;
  final DateTime createdAt;

  WalletPurchase({
    required this.id,
    required this.productName,
    required this.amountMinor,
    required this.currency,
    required this.paymentMethod,
    required this.status,
    required this.createdAt,
  });

  factory WalletPurchase.fromJson(Map<String, dynamic> j) => WalletPurchase(
        id: j['id'] as String,
        productName: j['product_name'] as String,
        amountMinor: j['amount_minor'] as int,
        currency: j['currency'] as String,
        paymentMethod: j['payment_method'] as String,
        status: j['status'] as String,
        createdAt: DateTime.parse(j['created_at'] as String),
      );

  String formattedPrice() {
    final symbol = switch (currency) {
      'GBP' => '£',
      'USD' => '\$',
      'EUR' => '€',
      _ => '$currency ',
    };
    final whole = amountMinor ~/ 100;
    final cents = amountMinor % 100;
    final body = cents == 0 ? '$whole' : '$whole.${cents.toString().padLeft(2, '0')}';
    return '$symbol$body';
  }
}

class AttendanceSummary {
  final int thisMonth;
  final int allTime;
  final int weekStreak;
  final List<int> weeklyCounts; // length 12, oldest → newest

  AttendanceSummary({
    required this.thisMonth,
    required this.allTime,
    required this.weekStreak,
    required this.weeklyCounts,
  });

  factory AttendanceSummary.fromJson(Map<String, dynamic> j) => AttendanceSummary(
        thisMonth: j['this_month'] as int,
        allTime: j['all_time'] as int,
        weekStreak: j['week_streak'] as int,
        weeklyCounts: ((j['weekly_counts'] as List?) ?? const []).cast<int>(),
      );
}

class UpcomingBooking {
  final String id;
  final String classId;
  final String title;
  final DateTime startsAt;
  final DateTime endsAt;
  final String roomName;
  final String instructorName;
  final String? instructorPhotoUrl;
  final String status;

  UpcomingBooking({
    required this.id,
    required this.classId,
    required this.title,
    required this.startsAt,
    required this.endsAt,
    required this.roomName,
    required this.instructorName,
    required this.instructorPhotoUrl,
    required this.status,
  });

  factory UpcomingBooking.fromJson(Map<String, dynamic> j) => UpcomingBooking(
        id: j['id'] as String,
        classId: j['class_id'] as String,
        title: j['title'] as String,
        startsAt: DateTime.parse(j['starts_at'] as String),
        endsAt: DateTime.parse(j['ends_at'] as String),
        roomName: j['room_name'] as String,
        instructorName: j['instructor_name'] as String,
        instructorPhotoUrl: j['instructor_photo_url'] as String?,
        status: (j['status'] as String?) ?? 'booked',
      );
}

class StaffMember {
  final String id;
  final String role;
  final String email;
  final String fullName;
  final String? photoUrl;

  StaffMember({
    required this.id,
    required this.role,
    required this.email,
    required this.fullName,
    required this.photoUrl,
  });

  factory StaffMember.fromJson(Map<String, dynamic> j) => StaffMember(
        id: j['id'] as String,
        role: j['role'] as String,
        email: j['email'] as String,
        fullName: j['full_name'] as String,
        photoUrl: j['photo_url'] as String?,
      );
}

class ScanResult {
  final String bookingId;
  final String userId;
  final String userName;
  final String classId;
  final String classTitle;
  final bool wasAlreadyAttended;

  ScanResult({
    required this.bookingId,
    required this.userId,
    required this.userName,
    required this.classId,
    required this.classTitle,
    required this.wasAlreadyAttended,
  });

  factory ScanResult.fromJson(Map<String, dynamic> j) => ScanResult(
        bookingId: j['booking_id'] as String,
        userId: j['user_id'] as String,
        userName: j['user_name'] as String,
        classId: j['class_id'] as String,
        classTitle: (j['class_title'] as String?) ?? '',
        wasAlreadyAttended: (j['was_already_attended'] as bool?) ?? false,
      );
}

class Promotion {
  final String id;
  final String title;
  final String body;
  final String imageUrl;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final bool isArchived;

  Promotion({
    required this.id,
    required this.title,
    required this.body,
    required this.imageUrl,
    required this.startsAt,
    required this.endsAt,
    required this.isArchived,
  });

  factory Promotion.fromJson(Map<String, dynamic> j) => Promotion(
        id: j['id'] as String,
        title: j['title'] as String,
        body: (j['body'] as String?) ?? '',
        imageUrl: (j['image_url'] as String?) ?? '',
        startsAt: (j['starts_at'] as String?) != null
            ? DateTime.tryParse(j['starts_at'] as String)
            : null,
        endsAt: (j['ends_at'] as String?) != null
            ? DateTime.tryParse(j['ends_at'] as String)
            : null,
        isArchived: (j['is_archived'] as bool?) ?? false,
      );
}

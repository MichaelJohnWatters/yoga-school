// Manager Console shell — 208 px sidebar + content area.
// Mirrors yoga-admin-ui.jsx KShell. Same semantic tokens as student app;
// desktop density (26/30 padding, generous air).

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/auth_state.dart';

import '../../api/models.dart';
import '../../api/api_error.dart';
import '../../theme/yoga_tokens.dart';
import '../../widgets/yoga_primitives.dart';
import 'admin_audit_screen.dart';
import 'admin_dashboard_screen.dart';
import 'admin_discounts_screen.dart';
import 'admin_payments_screen.dart';
import 'admin_product_editor_screen.dart';
import 'admin_products_screen.dart';
import 'admin_promotions_screen.dart';
import 'admin_reports_screen.dart';
import 'admin_roster_screen.dart';
import 'admin_schedule_screen.dart';
import 'admin_series_roster_screen.dart';
import 'admin_series_screen.dart';
import 'admin_settings_screen.dart';
import 'admin_student_detail_screen.dart';
import 'admin_staff_screen.dart';
import 'admin_students_screen.dart';
import 'admin_templates_screen.dart';
import 'admin_terminal_screen.dart';

enum ManagerSection {
  dashboard,
  schedule,
  templates,
  products,
  discounts,
  promotions,
  series,
  students,
  staff,
  roster,
  payments,
  terminal,
  reports,
  audit,
  settings,
}

/// Whether a section is visible at a given access tier. Mirrors the route
/// gating in server/internal/api/api.go — anything that hits a manager-only
/// endpoint must be manager-only here too, or instructors land on a screen
/// that immediately 403s. Series/Students are staff-visible because their
/// list + detail endpoints are staff-tier; the mutation buttons within those
/// screens still need to be hidden separately when role != manager.
bool isSectionVisible(ManagerSection s, AccessTier tier) {
  if (tier == AccessTier.manager) return true;
  if (tier != AccessTier.staff) return false;
  switch (s) {
    case ManagerSection.schedule:
    case ManagerSection.series:
    case ManagerSection.students:
    case ManagerSection.roster:
      return true;
    case ManagerSection.dashboard:
    case ManagerSection.templates:
    case ManagerSection.products:
    case ManagerSection.discounts:
    case ManagerSection.promotions:
    case ManagerSection.staff:
    case ManagerSection.payments:
    case ManagerSection.terminal:
    case ManagerSection.reports:
    case ManagerSection.audit:
    case ManagerSection.settings:
      return false;
  }
}

/// The section a new shell instance should land on, given the caller's tier.
ManagerSection defaultSectionForTier(AccessTier tier) =>
    tier == AccessTier.manager
        ? ManagerSection.dashboard
        : ManagerSection.schedule;

class ManagerShell extends StatefulWidget {
  final Me me;
  final StudioConfig studio;
  const ManagerShell({super.key, required this.me, required this.studio});

  @override
  State<ManagerShell> createState() => _ManagerShellState();
}

class _ManagerShellState extends State<ManagerShell> {
  late ManagerSection _section = defaultSectionForTier(widget.me.tier);
  String? _rosterClassId; // when set, Roster section deep-links to this class
  // Products section state. '' = create new; uuid = edit existing.
  String? _productEditId;
  // Students section state. When set, drill into that student's detail.
  String? _studentDetailId;
  // Series section state. When set, show that series' attendance grid.
  String? _seriesRosterId;

  void _navigate(ManagerSection s, {String? rosterClassId}) {
    setState(() {
      _section = s;
      _rosterClassId = rosterClassId;
      _productEditId = null;
      _studentDetailId = null;
      _seriesRosterId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    // Mobile breakpoint: below 900 px the sidebar collapses into a Drawer
    // behind a hamburger AppBar. Above, the persistent sidebar layout.
    final isNarrow = MediaQuery.of(context).size.width < 900;
    final sidebar = _Sidebar(
      active: _section,
      onSelect: (s) {
        _navigate(s);
        if (isNarrow) Navigator.of(context).maybePop();
      },
      manager: widget.me,
      studio: widget.studio,
    );
    final content = _Content(
      section: _section,
      me: widget.me,
      studio: widget.studio,
      rosterClassId: _rosterClassId,
      productEditId: _productEditId,
      studentDetailId: _studentDetailId,
      seriesRosterId: _seriesRosterId,
      onOpenRoster: (id) =>
          _navigate(ManagerSection.roster, rosterClassId: id),
      onNewProduct: () => setState(() => _productEditId = ''),
      onEditProduct: (id) => setState(() => _productEditId = id),
      onCloseProductEditor: () => setState(() => _productEditId = null),
      onOpenStudent: (id) => setState(() => _studentDetailId = id),
      onCloseStudent: () => setState(() => _studentDetailId = null),
      onOpenSeriesRoster: (id) =>
          setState(() => _seriesRosterId = id),
      onCloseSeriesRoster: () =>
          setState(() => _seriesRosterId = null),
    );
    if (isNarrow) {
      return Scaffold(
        backgroundColor: y.background,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: _MobileTopBar(
            studio: widget.studio,
            sectionLabel: _sectionLabel(_section),
            manager: widget.me,
          ),
        ),
        drawer: Drawer(
          backgroundColor: y.surface,
          shape: const RoundedRectangleBorder(),
          child: SafeArea(child: sidebar),
        ),
        body: SafeArea(top: false, child: content),
      );
    }
    return Scaffold(
      backgroundColor: y.background,
      body: Row(
        children: [
          SizedBox(width: 208, child: sidebar),
          Expanded(
            child: SafeArea(left: false, child: content),
          ),
        ],
      ),
    );
  }

  static String _sectionLabel(ManagerSection s) => switch (s) {
        ManagerSection.dashboard => 'Dashboard',
        ManagerSection.schedule => 'Schedule',
        ManagerSection.templates => 'Templates',
        ManagerSection.products => 'Products',
        ManagerSection.discounts => 'Discounts',
        ManagerSection.promotions => 'Promotions',
        ManagerSection.series => 'Series',
        ManagerSection.students => 'Students',
        ManagerSection.staff => 'Staff',
        ManagerSection.roster => 'Roster',
        ManagerSection.payments => 'Payments',
        ManagerSection.terminal => 'Terminal',
        ManagerSection.reports => 'Reports',
        ManagerSection.audit => 'Activity',
        ManagerSection.settings => 'Settings',
      };
}

class _MobileTopBar extends StatelessWidget {
  final StudioConfig studio;
  final String sectionLabel;
  final Me manager;
  const _MobileTopBar({
    required this.studio,
    required this.sectionLabel,
    required this.manager,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      decoration: BoxDecoration(
        color: y.surface,
        border: Border(bottom: BorderSide(color: y.border)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.menu, color: y.text),
                onPressed: () => Scaffold.of(context).openDrawer(),
              ),
              const SizedBox(width: 4),
              const YLogo(size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      sectionLabel,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: y.text,
                        height: 1.1,
                      ),
                    ),
                    Text(
                      '${studio.name} · ${manager.role.toUpperCase()}',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: y.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends ConsumerWidget {
  final ManagerSection active;
  final ValueChanged<ManagerSection> onSelect;
  final Me manager;
  final StudioConfig studio;
  const _Sidebar({
    required this.active,
    required this.onSelect,
    required this.manager,
    required this.studio,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    return Container(
      decoration: BoxDecoration(
        color: y.surface,
        border: Border(right: BorderSide(color: y.border)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 18),
            child: Row(
              children: [
                const YLogo(size: 30),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        studio.name,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                          color: y.text,
                        ),
                      ),
                      Text(
                        manager.role.toUpperCase(),
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: y.muted,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          for (final item in _items)
            if (isSectionVisible(item.section, manager.tier))
              _NavItem(
                icon: item.icon,
                label: item.label,
                active: item.section == active,
                onTap: () => onSelect(item.section),
              ),
          const Spacer(),
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: y.border)),
            ),
            child: InkWell(
              onTap: () => _showProfileMenu(context, ref),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.only(top: 10, left: 10, right: 10, bottom: 4),
                child: Row(
                  children: [
                    YAvatar(name: manager.fullName, size: 30),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            manager.fullName,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: y.text,
                            ),
                          ),
                          Text(
                            _roleLabel(manager.role),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: y.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.more_horiz, size: 18, color: y.muted),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showProfileMenu(BuildContext context, WidgetRef ref) async {
    final y = context.yoga;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    // Anchor the menu just above the profile row in the sidebar.
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final bottomLeft = box.localToGlobal(Offset(0, box.size.height), ancestor: overlay);
    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        bottomLeft.dx + 12,
        bottomLeft.dy - 120,
        overlay.size.width - bottomLeft.dx - 220,
        12,
      ),
      color: y.surface,
      elevation: 6,
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: 36,
          child: Text(
            manager.email,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: y.muted,
            ),
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'signout',
          height: 40,
          child: Row(
            children: [
              Icon(Icons.logout, size: 16, color: y.text),
              const SizedBox(width: 10),
              Text(
                'Sign out',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: y.text,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    if (result == 'signout') {
      await ref.read(authServiceProvider).signOut();
    }
  }

  static String _roleLabel(String r) {
    if (r.isEmpty) return r;
    return r[0].toUpperCase() + r.substring(1);
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _NavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: active ? y.primarySoft : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 17,
              color: active ? y.primaryStrong : y.muted,
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                color: active ? y.primaryStrong : y.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarItem {
  final ManagerSection section;
  final String label;
  final IconData icon;
  const _SidebarItem(this.section, this.label, this.icon);
}

const _items = <_SidebarItem>[
  _SidebarItem(ManagerSection.dashboard, 'Dashboard', Icons.dashboard_outlined),
  _SidebarItem(ManagerSection.schedule, 'Schedule', Icons.calendar_today_outlined),
  _SidebarItem(ManagerSection.templates, 'Templates', Icons.event_repeat_outlined),
  _SidebarItem(ManagerSection.products, 'Products', Icons.shopping_bag_outlined),
  _SidebarItem(ManagerSection.discounts, 'Discounts', Icons.local_offer_outlined),
  _SidebarItem(ManagerSection.promotions, 'Promotions', Icons.campaign_outlined),
  _SidebarItem(ManagerSection.series, 'Series', Icons.school_outlined),
  _SidebarItem(ManagerSection.students, 'Students', Icons.person_outline),
  _SidebarItem(ManagerSection.staff, 'Staff', Icons.badge_outlined),
  _SidebarItem(ManagerSection.roster, 'Roster', Icons.fact_check_outlined),
  _SidebarItem(ManagerSection.payments, 'Payments', Icons.warning_amber_outlined),
  _SidebarItem(ManagerSection.terminal, 'Terminal', Icons.point_of_sale_outlined),
  _SidebarItem(ManagerSection.reports, 'Reports', Icons.bar_chart_outlined),
  _SidebarItem(ManagerSection.audit, 'Activity', Icons.history),
  _SidebarItem(ManagerSection.settings, 'Settings', Icons.settings_outlined),
];

class _Content extends StatelessWidget {
  final ManagerSection section;
  final Me me;
  final StudioConfig studio;
  final String? rosterClassId;
  final String? productEditId;
  final String? studentDetailId;
  final String? seriesRosterId;
  final void Function(String classId) onOpenRoster;
  final VoidCallback onNewProduct;
  final void Function(String id) onEditProduct;
  final VoidCallback onCloseProductEditor;
  final void Function(String id) onOpenStudent;
  final VoidCallback onCloseStudent;
  final void Function(String id) onOpenSeriesRoster;
  final VoidCallback onCloseSeriesRoster;
  const _Content({
    required this.section,
    required this.me,
    required this.studio,
    required this.rosterClassId,
    required this.productEditId,
    required this.studentDetailId,
    required this.seriesRosterId,
    required this.onOpenRoster,
    required this.onNewProduct,
    required this.onEditProduct,
    required this.onCloseProductEditor,
    required this.onOpenStudent,
    required this.onCloseStudent,
    required this.onOpenSeriesRoster,
    required this.onCloseSeriesRoster,
  });

  @override
  Widget build(BuildContext context) {
    // Backstop for direct navigation (e.g. URL hack on web) — if the caller
    // somehow lands on a section their tier shouldn't see, render a clean
    // placeholder rather than letting the screen blow up on the inevitable
    // 403 from its data calls.
    if (!isSectionVisible(section, me.tier)) {
      return const _SectionUnavailable();
    }
    return switch (section) {
      ManagerSection.dashboard =>
        AdminDashboardScreen(me: me, onOpenRoster: onOpenRoster),
      ManagerSection.schedule => AdminScheduleScreen(onOpenRoster: onOpenRoster),
      ManagerSection.templates => const AdminTemplatesScreen(),
      ManagerSection.roster => rosterClassId == null
          ? _RosterPicker(onPick: onOpenRoster)
          : AdminRosterScreen(classId: rosterClassId!),
      ManagerSection.products => productEditId == null
          ? AdminProductsScreen(onNew: onNewProduct, onEdit: onEditProduct)
          : AdminProductEditorScreen(
              productId: productEditId!.isEmpty ? null : productEditId,
              onClose: onCloseProductEditor,
            ),
      ManagerSection.discounts => const AdminDiscountsScreen(),
      ManagerSection.promotions => const AdminPromotionsScreen(),
      ManagerSection.series => seriesRosterId == null
          ? AdminSeriesScreen(onView: onOpenSeriesRoster)
          : AdminSeriesRosterScreen(
              enrollmentId: seriesRosterId!,
              onClose: onCloseSeriesRoster,
            ),
      ManagerSection.students => studentDetailId == null
          ? AdminStudentsScreen(onView: onOpenStudent)
          : AdminStudentDetailScreen(
              studentId: studentDetailId!,
              onClose: onCloseStudent,
              onOpenClass: onOpenRoster,
            ),
      ManagerSection.staff => AdminStaffScreen(me: me),
      ManagerSection.payments => const AdminPaymentsScreen(),
      ManagerSection.terminal => const AdminTerminalScreen(),
      ManagerSection.reports => const AdminReportsScreen(),
      ManagerSection.audit => const AdminAuditScreen(),
      ManagerSection.settings => AdminSettingsScreen(studio: studio),
    };
  }
}

class _SectionUnavailable extends StatelessWidget {
  const _SectionUnavailable();

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 28, color: y.muted),
            const SizedBox(height: 10),
            Text(
              'Not available for your role',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: y.text,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Ask a manager if you need access.',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: y.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Landing for the Roster sidebar tab — pick today's class to roster.
class _RosterPicker extends ConsumerWidget {
  final void Function(String classId) onPick;
  const _RosterPicker({required this.onPick});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dash = ref.watch(adminDashboardProvider);
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: dash.when(
        data: (d) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const ManagerPageHeader(
              title: 'Roster',
              sub: 'Pick a class to work through',
            ),
            Expanded(
              child: ManagerCard(
                title: "Today's classes",
                child: d.classesToday.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'No classes scheduled today.',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: y.muted,
                          ),
                        ),
                      )
                    : Column(
                        children: [
                          for (var i = 0; i < d.classesToday.length; i++)
                            _RosterPickRow(
                              row: d.classesToday[i],
                              isLast: i == d.classesToday.length - 1,
                              onTap: () => onPick(d.classesToday[i].id),
                            ),
                        ],
                      ),
              ),
            ),
          ],
        ),
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (e, _) => Center(
          child: Text(
            "Can't load: ${ApiError.fromAny(e).message}",
            style: TextStyle(color: y.muted),
          ),
        ),
      ),
    );
  }
}

class _RosterPickRow extends StatelessWidget {
  final ClassRow row;
  final bool isLast;
  final VoidCallback onTap;
  const _RosterPickRow({
    required this.row,
    required this.isLast,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final local = row.startsAt.toLocal();
    final hh = '${local.hour}:${local.minute.toString().padLeft(2, '0')}';
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        decoration: BoxDecoration(
          border: isLast
              ? null
              : Border(bottom: BorderSide(color: y.border)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 64,
              child: Text(
                hh,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: y.text,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                row.title,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: y.text,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${row.bookedCount} / ${row.capacity}',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: y.muted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 16),
            Icon(Icons.chevron_right, size: 18, color: y.muted),
          ],
        ),
      ),
    );
  }
}

/// Page header used by every manager screen — title + optional sub + actions.
class ManagerPageHeader extends StatelessWidget {
  final String title;
  final String? sub;
  final List<Widget>? actions;
  const ManagerPageHeader({
    super.key,
    required this.title,
    this.sub,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: y.text,
                  ),
                ),
                if (sub != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    sub!,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: y.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (actions != null)
            Row(
              children: [
                for (var i = 0; i < actions!.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  actions![i],
                ],
              ],
            ),
        ],
      ),
    );
  }
}

/// Desktop card primitive matching KCard.
class ManagerCard extends StatelessWidget {
  final String? title;
  final String? action;
  final VoidCallback? onAction;
  final Widget child;
  final EdgeInsets padding;
  /// When true, wraps the child in Expanded so it fills remaining vertical
  /// space inside the card. Only safe when the card itself sits in a bounded
  /// parent (e.g. an Expanded inside a Column).
  final bool fill;
  const ManagerCard({
    super.key,
    this.title,
    this.action,
    this.onAction,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.fill = false,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null || action != null) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Text(
                      title ?? '',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                        color: y.text,
                      ),
                    ),
                  ),
                  if (action != null)
                    GestureDetector(
                      onTap: onAction,
                      child: Text(
                        action!,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: y.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (fill) Expanded(child: child) else child,
        ],
      ),
    );
  }
}

/// Single stat tile for the dashboard.
class ManagerStat extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final bool accent;
  const ManagerStat({
    super.key,
    required this.label,
    required this.value,
    this.sub,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return ManagerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: y.muted,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.7,
              color: accent ? y.accent : y.text,
              height: 1.0,
            ),
          ),
          if (sub != null) ...[
            const SizedBox(height: 4),
            Text(
              sub!,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: y.muted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Horizontal capacity meter — 6 px track + tabular-num label.
class ManagerMeter extends StatelessWidget {
  final int percent;
  final String label;
  const ManagerMeter({super.key, required this.percent, required this.label});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final full = percent >= 100;
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 6,
            decoration: BoxDecoration(
              color: y.surface2,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: (percent.clamp(0, 100)) / 100.0,
                child: Container(
                  decoration: BoxDecoration(
                    color: full ? y.accent : y.primary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: y.muted,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

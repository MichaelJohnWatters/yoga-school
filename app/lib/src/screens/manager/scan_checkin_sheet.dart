// Manager scan-check-in sheet.
//
// V1 is manual entry: a TextField + a "Scan" button. The manager pastes or
// types the token they read off the student's QR (the QR encodes a plain
// string; a paired hardware barcode reader inputs it as keyboard text).
// Camera scanning is a follow-up — it would just call into _submit() with
// the decoded payload, so the rest of this widget stays unchanged.
//
// On success, the sheet shows the student name + class title with a green
// affirmation. On a typed refusal (invalid token, outside window, etc.)
// it shows a coloured error block but keeps the field around so the
// manager can fix the token and try again.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../theme/yoga_tokens.dart';

/// Pops `true` if at least one successful scan happened during the session
/// — caller uses that to know whether to refresh the roster.
Future<bool?> showScanCheckinSheet(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierColor: const Color(0x80100A05),
    builder: (_) => const Center(
      child: SizedBox(width: 460, child: _ScanSheet()),
    ),
  );
}

class _ScanSheet extends ConsumerStatefulWidget {
  const _ScanSheet();

  @override
  ConsumerState<_ScanSheet> createState() => _ScanSheetState();
}

class _ScanSheetState extends ConsumerState<_ScanSheet> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  ScanResult? _lastSuccess;
  String? _errorCode;
  String? _errorMessage;
  bool _anySuccess = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final token = _ctrl.text.trim();
    if (token.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _errorCode = null;
      _errorMessage = null;
    });
    try {
      final res =
          await ref.read(apiClientProvider).adminCheckinScan(token: token);
      setState(() {
        _lastSuccess = res;
        _anySuccess = true;
        _ctrl.clear();
      });
    } on ScanConflict catch (e) {
      setState(() {
        _errorCode = e.code;
        _errorMessage = _friendlyMessage(e);
        _lastSuccess = null;
      });
    } catch (e) {
      setState(() {
        _errorCode = 'unknown';
        _errorMessage = 'Scan failed: ${ApiError.fromAny(e).message}';
        _lastSuccess = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Map server codes onto a sentence the front-desk staff can act on.
  String _friendlyMessage(ScanConflict e) {
    switch (e.code) {
      case 'invalid_token':
        return 'Token not recognised. It may have already been scanned, or '
            'the student needs to refresh their QR.';
      case 'was_cancelled':
        return 'Booking was cancelled — no admission.';
      case 'outside_checkin_window':
        return 'Check-in opens 30 min before class and closes 10 min after '
            'the end. Try once they\'re closer to the start.';
      default:
        return e.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: BorderRadius.circular(y.radiusCard),
          border: Border.all(color: y.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.qr_code_scanner, size: 22, color: y.text),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Scan check-in',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: y.text,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(_anySuccess),
                  child: Icon(Icons.close, size: 18, color: y.muted),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Paste or type the student\'s code, or scan with a paired '
              'barcode reader (input lands in the field).',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: y.muted,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 18),
            _TokenField(
              controller: _ctrl,
              busy: _busy,
              onSubmit: _submit,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _PrimaryBtn(
                    label: _busy ? 'Checking…' : 'Mark attended',
                    enabled: !_busy && _ctrl.text.trim().isNotEmpty,
                    onTap: _submit,
                  ),
                ),
              ],
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              _Block(
                bg: const Color(0x1AA33B2E),
                fg: const Color(0xFFA33B2E),
                icon: Icons.error_outline,
                title: _errorCode == 'outside_checkin_window'
                    ? 'Outside check-in window'
                    : _errorCode == 'was_cancelled'
                        ? 'Booking was cancelled'
                        : 'Scan refused',
                body: _errorMessage!,
              ),
            ],
            if (_lastSuccess != null) ...[
              const SizedBox(height: 16),
              _Block(
                bg: y.primarySoft,
                fg: y.primary,
                icon: _lastSuccess!.wasAlreadyAttended
                    ? Icons.history_toggle_off
                    : Icons.check_circle_outline,
                title: _lastSuccess!.wasAlreadyAttended
                    ? '${_lastSuccess!.userName} · already checked in'
                    : '${_lastSuccess!.userName} · checked in',
                body: _lastSuccess!.classTitle.isEmpty
                    ? 'No class title — booking id ${_lastSuccess!.bookingId}'
                    : _lastSuccess!.classTitle,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TokenField extends StatelessWidget {
  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSubmit;
  const _TokenField({
    required this.controller,
    required this.busy,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: y.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: y.border),
      ),
      child: TextField(
        controller: controller,
        autofocus: true,
        enabled: !busy,
        onSubmitted: (_) => onSubmit(),
        textInputAction: TextInputAction.go,
        inputFormatters: [
          // Tokens are URL-safe ASCII — strip incidental whitespace and any
          // characters a paired scanner might inject around the payload.
          FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_\-]')),
        ],
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: 'e.g. b8dad8989f10e7b5',
          hintStyle: TextStyle(
            color: y.muted,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        style: TextStyle(
          color: y.text,
          fontSize: 15,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _PrimaryBtn extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  const _PrimaryBtn({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final bg = enabled ? y.primary : y.borderStrong;
    final fg = enabled ? y.onPrimary : y.muted;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: fg,
            fontSize: 14,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}

class _Block extends StatelessWidget {
  final Color bg;
  final Color fg;
  final IconData icon;
  final String title;
  final String body;
  const _Block({
    required this.bg,
    required this.fg,
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: fg,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: y.text,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

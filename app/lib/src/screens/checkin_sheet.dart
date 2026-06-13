// Check-in QR — bottom sheet shown when Book header's barcode button is tapped.
// Card is always white for scanner contrast, regardless of theme/dark mode
// (per yoga-onboard.jsx).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';

class CheckInSheet extends ConsumerStatefulWidget {
  const CheckInSheet({super.key});

  @override
  ConsumerState<CheckInSheet> createState() => _CheckInSheetState();
}

class _CheckInSheetState extends ConsumerState<CheckInSheet> {
  late Future<CheckInPayload> _payload;

  @override
  void initState() {
    super.initState();
    _payload = ref.read(apiClientProvider).checkInCode();
  }

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: y.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
        child: SafeArea(
          top: false,
          child: FutureBuilder<CheckInPayload>(
            future: _payload,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 60),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Text(
                    "Can't load check-in code: ${snap.error}",
                    style: TextStyle(color: y.muted),
                  ),
                );
              }
              return _Loaded(payload: snap.data!);
            },
          ),
        ),
      ),
    );
  }
}

class _Loaded extends StatelessWidget {
  final CheckInPayload payload;
  const _Loaded({required this.payload});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: y.borderStrong,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 18),
        // The scanner card is always white-on-black for contrast,
        // regardless of the active theme.
        Container(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFE6E1DA)),
          ),
          child: Column(
            children: [
              SizedBox(
                width: 200,
                height: 200,
                child: QrImageView(
                  data: payload.token,
                  version: QrVersions.auto,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Color(0xFF111111),
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Color(0xFF111111),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                payload.token,
                style: const TextStyle(
                  color: Color(0xFF111111),
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2.5,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Text(
          payload.userName,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: y.text,
          ),
        ),
        if (payload.nextClass != null) ...[
          const SizedBox(height: 6),
          Center(
            child: Text(
              'Booked · ${_meta(payload.nextClass!)}',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: y.muted,
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          'Show this at the front desk scanner.\nScreen brightness raised automatically.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: y.muted,
            height: 1.45,
          ),
        ),
      ],
    );
  }

  static String _meta(UpcomingBooking b) {
    final t = b.startsAt.toLocal();
    const dows = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final hh = '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
    return '${b.title} · ${dows[(t.weekday + 6) % 7]} ${t.day} $hh';
  }
}

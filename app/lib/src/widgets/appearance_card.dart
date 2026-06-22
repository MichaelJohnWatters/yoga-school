// Appearance — Light / Dark / Auto pill card.
//
// Shared by the student Profile screen and the manager Settings screen
// so the per-user theme toggle lives in one place. Optimistic: the tap
// re-themes the app instantly via [themeModePrefProvider], then persists
// server-side. Auto follows the OS / browser brightness.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/models.dart';
import '../theme/yoga_tokens.dart';

class AppearanceCard extends ConsumerWidget {
  const AppearanceCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final y = context.yoga;
    final pref = ref.watch(themeModePrefProvider);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: y.surface,
        borderRadius: BorderRadius.circular(y.radiusCard),
        border: Border.all(color: y.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.brightness_6_outlined, size: 16, color: y.text),
              const SizedBox(width: 8),
              Text(
                'Appearance',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                  color: y.text,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Auto follows your device. Light and Dark pin the studio theme.',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              height: 1.45,
              color: y.muted,
            ),
          ),
          const SizedBox(height: 12),
          _ThemeModeRow(
            current: pref,
            onPick: (next) async {
              try {
                await ref.read(themeModePrefProvider.notifier).set(next);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Couldn't save: ${ApiError.fromAny(e).message}")),
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }
}

class _ThemeModeRow extends StatelessWidget {
  final ThemeModePref current;
  final ValueChanged<ThemeModePref> onPick;
  const _ThemeModeRow({required this.current, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    const options = <(ThemeModePref, String, IconData)>[
      (ThemeModePref.light, 'Light', Icons.light_mode_outlined),
      (ThemeModePref.dark, 'Dark', Icons.dark_mode_outlined),
      (ThemeModePref.system, 'Auto', Icons.brightness_auto_outlined),
    ];
    return Row(
      children: [
        for (final (mode, label, icon) in options) ...[
          Expanded(
            child: GestureDetector(
              onTap: () => onPick(mode),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: mode == current ? y.primarySoft : y.surface2,
                  borderRadius: BorderRadius.circular(y.radiusChip),
                  border: Border.all(
                    color: mode == current ? y.primary : y.border,
                    width: mode == current ? 1.4 : 1,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon,
                        size: 18,
                        color: mode == current ? y.primaryStrong : y.text),
                    const SizedBox(height: 4),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.1,
                        color: mode == current ? y.primaryStrong : y.text,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (mode != options.last.$1) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

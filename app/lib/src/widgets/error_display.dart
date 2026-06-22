// Error display helpers — keep the "safe in prod, verbose in dev" rule
// in one place so every catch site can opt in without re-implementing it.
//
// Two surfaces:
//   * showApiErrorSnack(context, err) — toss it into a SnackBar with the
//     debug raw text appended in a code style when present.
//   * ApiErrorBox(error: ...) — inline widget for error rows inside a
//     dialog / sheet / settings card. Same content rules.
//
// Both accept any Object — callers can pass an ApiError, a DioException,
// or anything else, and ApiError.fromAny normalises it.

import 'package:flutter/material.dart';

import '../api/api_error.dart';
import '../theme/yoga_tokens.dart';

/// Show [err] as a SnackBar. Renders the safe message; appends a
/// monospace debug line below it when running in debug mode AND the
/// server included a `_debug` payload.
void showApiErrorSnack(BuildContext context, Object err) {
  final api = ApiError.fromAny(err);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(api.message),
          if (api.showDebug) ...[
            const SizedBox(height: 6),
            Text(
              _debugLine(api),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

/// Inline error block for use inside dialogs / sheets / settings cards.
/// Same display rules as the snackbar variant — safe message on top,
/// optional dev debug line beneath in monospace.
class ApiErrorBox extends StatelessWidget {
  final Object error;
  const ApiErrorBox({super.key, required this.error});

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final api = ApiError.fromAny(error);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: y.accentSoft,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: y.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            api.message,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFFA33B2E),
            ),
          ),
          if (api.showDebug) ...[
            const SizedBox(height: 6),
            Text(
              _debugLine(api),
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
                color: y.muted,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Format the debug line consistently across surfaces. Always prefixed
/// with `[dev]` so the on-screen text is unmistakably a developer aid
/// and not a localised production message someone forgot to translate.
String _debugLine(ApiError api) {
  final d = api.debug!;
  if (d.where.isEmpty) return '[dev] ${d.raw}';
  return '[dev] ${d.where}: ${d.raw}';
}

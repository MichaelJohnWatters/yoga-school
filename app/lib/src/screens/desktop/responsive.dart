// Breakpoint helpers for the student-app desktop reflow.
//
// Per the design handoff: below ~900 px logical width use the mobile
// layouts + tab bar; above, the top-nav DesktopShell. 1040 px is the
// content-column max width (28 px top padding).

import 'package:flutter/widgets.dart';

const double kDesktopBreakpoint = 900;
const double kDesktopContentMaxWidth = 1040;

bool isDesktop(BuildContext context) =>
    MediaQuery.of(context).size.width >= kDesktopBreakpoint;

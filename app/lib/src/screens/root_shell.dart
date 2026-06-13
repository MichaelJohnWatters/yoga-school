// Bottom tab shell. Home is implemented; the rest are stubs until their
// endpoints come online.
//
// Tab structure: Home / Book / Buy / Profile / More.
// (The spec calls for 4 tabs but the design adds Home as leading 5th —
// flagged in the design README; reconcile before shipping.)

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/yoga_tokens.dart';
import 'book_screen.dart';
import 'buy_screen.dart';
import 'home_screen.dart';
import 'more_screen.dart';
import 'profile_screen.dart';

class RootShell extends StatefulWidget {
  final Me me;
  final StudioConfig studio;
  const RootShell({super.key, required this.me, required this.studio});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  static const _tabs = [
    (label: 'Home', icon: Icons.home_outlined),
    (label: 'Book', icon: Icons.calendar_today_outlined),
    (label: 'Buy', icon: Icons.shopping_bag_outlined),
    (label: 'Profile', icon: Icons.person_outline),
    (label: 'More', icon: Icons.more_horiz),
  ];

  @override
  Widget build(BuildContext context) {
    final y = context.yoga;
    final pages = <Widget>[
      HomeScreen(me: widget.me, studio: widget.studio),
      const BookScreen(),
      const BuyScreen(),
      ProfileScreen(me: widget.me),
      const MoreScreen(),
    ];
    return Scaffold(
      backgroundColor: y.background,
      body: SafeArea(
        bottom: false,
        child: IndexedStack(index: _index, children: pages),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: y.surface,
          border: Border(top: BorderSide(color: y.border)),
        ),
        padding: const EdgeInsets.only(top: 8, bottom: 26, left: 8, right: 8),
        child: Row(
          children: [
            for (var i = 0; i < _tabs.length; i++)
              Expanded(
                child: InkWell(
                  onTap: () => setState(() => _index = i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _tabs[i].icon,
                          size: 23,
                          color: i == _index ? y.primary : y.muted,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _tabs[i].label,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: i == _index ? FontWeight.w700 : FontWeight.w600,
                            color: i == _index ? y.primary : y.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}


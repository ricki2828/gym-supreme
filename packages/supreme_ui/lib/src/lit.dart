import 'package:flutter/material.dart';

/// LIT: Gym Supreme's light direction (direction B, plan 18 and 19; mockup
/// source gym-supreme-jam/src/d.py). Light ground, ink type, five session
/// type colours. Cyan is earned: personal bests only, never a session type.
abstract final class Lit {
  // Ground and ink
  static const Color ground = Color(0xFFFBFBF9);
  static const Color ink = Color(0xFF121417);
  static const Color inkSecondary = Color(0xFF4A5058);
  static const Color inkQuiet = Color(0xFF6C747E);
  static const Color hair = Color(0xFFE3E5E0);

  // Session types. Selection takes the type's colour; a mixed pick uses ink.
  static const Color push = Color(0xFFFF6EC7);

  /// Mid blue, moved off ice blue: ice sat too close to PB cyan (plan 18).
  static const Color pull = Color(0xFF6FA0FF);
  static const Color legs = Color(0xFF8CFF5C);
  static const Color engine = Color(0xFF6D3FE0);
  static const Color core = Color(0xFFFFB78F);

  /// Rest screen: sand, deliberately none of the type colours or PB cyan, so
  /// a Pull day's rest no longer reads as the Pull set screen it follows.
  static const Color rest = Color(0xFFE4DDCB);

  /// Personal bests only.
  static const Color pb = Color(0xFF19E6FF);
  static const Color pbInk = Color(0xFF06252B);

  static const List<Color> sessionTypes = [push, pull, legs, engine, core];
}

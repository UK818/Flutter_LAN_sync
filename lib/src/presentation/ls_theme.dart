import 'package:flutter/material.dart';

/// Internal color palette for the package UI.
/// All UI widgets use these instead of host-app color constants — kept as
/// a separate palette rather than importing host-app color constants, so the
/// package stays usable across applications. Host apps can override any of
/// these colors through [LanSyncTheme].
class LanSyncTheme {
  final Color? primary;
  final Color? success;
  final Color? warning;
  final Color? danger;
  final Color? info;
  final Color? purple;
  final Color? text;
  final Color? subText;
  final Color? hint;
  final Color? border;
  final Color? background;
  final Color? white;

  const LanSyncTheme({
    this.primary,
    this.success,
    this.warning,
    this.danger,
    this.info,
    this.purple,
    this.text,
    this.subText,
    this.hint,
    this.border,
    this.background,
    this.white,
  });
}

class LsColors {
  LsColors._();

  static LanSyncTheme? _customTheme;

  static void setTheme(LanSyncTheme? theme) => _customTheme = theme;

  // Default palette used when the host does not provide a theme.
  static Color get primary => _customTheme?.primary ?? const Color(0xFF313C65);
  static Color get success => _customTheme?.success ?? const Color(0xFF16A34A);
  static Color get warning => _customTheme?.warning ?? const Color(0xFFD97706);
  static Color get danger => _customTheme?.danger ?? const Color(0xFFDC2626);
  static Color get info => _customTheme?.info ?? const Color(0xFF0284C7);
  static Color get purple => _customTheme?.purple ?? const Color(0xFF7C3AED);

  static Color get text => _customTheme?.text ?? const Color(0xFF1A1F36);
  static Color get subText => _customTheme?.subText ?? const Color(0xFF5A5B6B);
  static Color get hint => _customTheme?.hint ?? const Color(0xFFABADB8);
  static Color get border => _customTheme?.border ?? const Color(0xFFE2E4EE);
  static Color get background =>
      _customTheme?.background ?? const Color(0xFFE8EBF4);
  static Color get white => _customTheme?.white ?? const Color(0xFFFFFFFF);
}

/// Spacing helpers so we don't depend on flutter_screenutil.
class Ls {
  Ls._();

  static double w(double v) => v;
  static double h(double v) => v;
  static double sp(double v) => v;
  static double r(double v) => v;
}

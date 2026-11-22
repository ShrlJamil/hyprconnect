import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

/// Shortcut so widgets write context.l10n.someString. The OS picks
/// the locale: English is the source language, Indonesian ships as
/// a translation, and any other system language falls back to
/// English.
extension AppL10n on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

//! Localized display strings for the plugin catalog. The catalog
//! itself (plugin_settings.dart) carries only stable ids since the
//! English-first localization pass; these resolvers map an id to
//! its ARB-backed title, description, and device-page tile title.

import '../../l10n/app_localizations.dart';

String pluginTitle(AppLocalizations l, String id) => switch (id) {
  'clipboard' => l.pluginClipboard,
  'share' => l.pluginShare,
  'notification' => l.pluginNotification,
  'mpris' => l.pluginMpris,
  'systemvolume' => l.pluginSystemVolume,
  'sftp' => l.pluginSftp,
  'presenter' => l.pluginPresenter,
  'remoteinput' => l.pluginRemoteInput,
  'battery' => l.pluginBattery,
  'findmyphone' => l.pluginFindMyPhone,
  'runcommand' => l.pluginRunCommand,
  _ => id,
};

String pluginDescription(AppLocalizations l, String id) => switch (id) {
  'clipboard' => l.pluginClipboardDesc,
  'share' => l.pluginShareDesc,
  'notification' => l.pluginNotificationDesc,
  'mpris' => l.pluginMprisDesc,
  'systemvolume' => l.pluginSystemVolumeDesc,
  'sftp' => l.pluginSftpDesc,
  'presenter' => l.pluginPresenterDesc,
  'remoteinput' => l.pluginRemoteInputDesc,
  'battery' => l.pluginBatteryDesc,
  'findmyphone' => l.pluginFindMyPhoneDesc,
  'runcommand' => l.pluginRunCommandDesc,
  _ => '',
};

String pluginTileTitle(AppLocalizations l, String id) => switch (id) {
  'clipboard' => l.pluginClipboardTile,
  'share' => l.pluginShareTile,
  'presenter' => l.pluginPresenterTile,
  'mpris' => l.pluginMprisTile,
  'remoteinput' => l.pluginRemoteInputTile,
  'runcommand' => l.pluginRunCommandTile,
  _ => pluginTitle(l, id),
};

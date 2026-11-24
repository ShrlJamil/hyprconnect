// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get about => 'About';

  @override
  String get aboutBody =>
      'Companion app for the HyprConnect daemon on your desktop. It speaks the KDE Connect protocol, so it can still talk to the stock KDE Connect on desktops and other phones.';

  @override
  String get accelHigh => 'High';

  @override
  String get accelLow => 'Low';

  @override
  String get accelMedium => 'Medium';

  @override
  String get accelOff => 'Off';

  @override
  String get accept => 'Accept';

  @override
  String get addSlide => 'Add slide';

  @override
  String arrivesInPhase(String phase) {
    return 'Arrives in phase $phase';
  }

  @override
  String get automatic => 'Automatic';

  @override
  String get back => 'Back';

  @override
  String get cancel => 'Cancel';

  @override
  String get cancelRequest => 'Cancel request';

  @override
  String get certFingerprint => 'Certificate fingerprint (SHA-256)';

  @override
  String get clipboardEmpty => 'Clipboard is empty or not text.';

  @override
  String clipboardSendFailed(String error) {
    return 'Failed to send clipboard: $error';
  }

  @override
  String get clipboardSent => 'Clipboard sent';

  @override
  String get connect => 'Connect';

  @override
  String get connectFailed => 'Failed to connect. Check the log in Settings.';

  @override
  String get copy => 'Copy';

  @override
  String get createNotes => 'Create notes';

  @override
  String get deviceIdLabel => 'Device ID';

  @override
  String get deviceMenu => 'Device menu';

  @override
  String get deviceOffline => 'Device offline';

  @override
  String get devices => 'Devices';

  @override
  String get doubleTapToDrag => 'Double tap to drag';

  @override
  String get dragAndDropBehavior => 'Drag and drop behavior';

  @override
  String get editCommandsOnDesktop => 'Edit the command list on the desktop';

  @override
  String get editNotes => 'Edit notes';

  @override
  String get enableGyroMouse => 'Enable gyroscope mouse';

  @override
  String get encryptedConnection => 'Encrypted connection (TLS)';

  @override
  String get encryptionDisconnectedBody =>
      'Connect the device first to see the encryption details of this channel.';

  @override
  String get encryptionInfo => 'Encryption info';

  @override
  String get encryptionPairedBody =>
      'This device is paired. Every packet travels over TLS with self-signed certificates that were exchanged during pairing.';

  @override
  String get encryptionUnpairedBody =>
      'The TLS channel is up, but this device is not paired yet. Pair first so its certificate becomes trusted.';

  @override
  String fileSendFailed(String error) {
    return 'Failed to send file: $error';
  }

  @override
  String fileSent(String name) {
    return 'Sent: $name';
  }

  @override
  String get forward10 => 'Forward 10 seconds';

  @override
  String get fullscreen => 'Fullscreen';

  @override
  String get functionKeys => 'Function keys F1 to F12';

  @override
  String get gyroSensitivity => 'Gyroscope sensitivity';

  @override
  String get howPairingWorksBody =>
      'Each device creates its own certificate, signed by no authority. Trust is built once during pairing: the verification key above is computed from both devices\' public keys, and you compare it on both sides before tapping Accept. After that the peer certificate is stored and later connections are trusted automatically.';

  @override
  String get howPairingWorksTitle => 'How pairing works';

  @override
  String get keyboard => 'Keyboard';

  @override
  String get log => 'Log';

  @override
  String get menu => 'Menu';

  @override
  String get next => 'Next';

  @override
  String get nextSlideNotes => 'Next slide notes';

  @override
  String get noAudioDeviceFound => 'No audio device found';

  @override
  String get noCommandsYet =>
      'The desktop has no commands to run yet.\nAdd them through the editor on the desktop.';

  @override
  String get noConnection => 'No connection to this device.';

  @override
  String get noDeviceOnNetwork => 'No device on this network yet';

  @override
  String get noPairedDeviceBody =>
      'Open the sidebar and choose Pair new device to connect your first desktop.';

  @override
  String get noPairedDeviceTitle => 'No device paired yet.';

  @override
  String get noPlayerFound => 'No player found';

  @override
  String get notConnected => 'Not connected';

  @override
  String get notLoaded => 'Not loaded yet';

  @override
  String get notesHint => 'Notes for this slide';

  @override
  String get openNotesFile => 'Open notes file';

  @override
  String get openingCommandEditor =>
      'Opening the command editor on the desktop';

  @override
  String pairFirst(String device, String title) {
    return 'Pair with $device first to use $title.';
  }

  @override
  String get pairNewDevice => 'Pair new device';

  @override
  String get pairingRequest => 'Pairing request';

  @override
  String get pairingRequestBody =>
      'The desktop is asking to pair. Match this key with the one shown on the desktop, then tap Accept.';

  @override
  String get pasteFromClipboard => 'Paste from clipboard';

  @override
  String get pause => 'Pause';

  @override
  String get peerDevice => 'Peer device';

  @override
  String pingSent(String name) {
    return 'Ping sent to $name.';
  }

  @override
  String get play => 'Play';

  @override
  String get pluginBattery => 'Battery';

  @override
  String get pluginBatteryDesc =>
      'Send this phone\'s battery status to the desktop.';

  @override
  String get pluginClipboard => 'Clipboard';

  @override
  String get pluginClipboardDesc =>
      'Send and receive clipboard contents with the desktop.';

  @override
  String get pluginClipboardTile => 'Send clipboard';

  @override
  String pluginDisabledSnack(String title) {
    return 'The $title plugin is off. Enable it in Plugin settings.';
  }

  @override
  String get pluginFindMyPhone => 'Find my phone';

  @override
  String get pluginFindMyPhoneDesc => 'Ring this phone from the desktop.';

  @override
  String get pluginMpris => 'Multimedia control';

  @override
  String get pluginMprisDesc =>
      'Play, pause, and switch tracks on the desktop.';

  @override
  String get pluginMprisTile => 'Multimedia control';

  @override
  String get pluginNotification => 'Notifications';

  @override
  String get pluginNotificationDesc =>
      'Show desktop notifications on this phone.';

  @override
  String get pluginPresenter => 'Presentation remote';

  @override
  String get pluginPresenterDesc =>
      'Control presentations and point with the pointer.';

  @override
  String get pluginPresenterTile => 'Presentation remote';

  @override
  String get pluginRemoteInput => 'Remote input';

  @override
  String get pluginRemoteInputDesc => 'Touchpad and keyboard for the desktop.';

  @override
  String get pluginRemoteInputTile => 'Remote input';

  @override
  String get pluginRunCommand => 'Run commands';

  @override
  String get pluginRunCommandDesc =>
      'Run commands on the desktop and see their output.';

  @override
  String get pluginRunCommandTile => 'Run Commands';

  @override
  String pluginSettingsHeader(String device) {
    return 'Plugins for $device. Changes apply when the device reconnects.';
  }

  @override
  String get pluginSettingsTitle => 'Plugin settings';

  @override
  String get pluginSftp => 'Browse files (SFTP)';

  @override
  String get pluginSftpDesc => 'Access desktop files over SFTP.';

  @override
  String get pluginShare => 'Send file';

  @override
  String get pluginShareDesc =>
      'Send files to the desktop and receive files from it.';

  @override
  String get pluginShareTile => 'Send file';

  @override
  String get pluginSystemVolume => 'System volume';

  @override
  String get pluginSystemVolumeDesc => 'Control the desktop speaker volume.';

  @override
  String get previous => 'Previous';

  @override
  String get previousSlideNotes => 'Previous slide notes';

  @override
  String get receivedFilesFolder => 'Received files folder';

  @override
  String get refresh => 'Refresh';

  @override
  String get reject => 'Reject';

  @override
  String get reloadList => 'Reload list';

  @override
  String get remoteInputSettingsTitle => 'Remote Input settings';

  @override
  String get requestPairing => 'Request pairing';

  @override
  String get reverseScrollDirection => 'Reverse scroll direction';

  @override
  String get rewind10 => 'Back 10 seconds';

  @override
  String get sameWifiHint =>
      'Make sure the desktop and this phone are on the same Wi-Fi.';

  @override
  String get scrollSensitivity => 'Scroll sensitivity';

  @override
  String get send => 'Send';

  @override
  String get sendPing => 'Send ping';

  @override
  String get sendText => 'Send text';

  @override
  String get sendingFile => 'Sending file';

  @override
  String get sensDefault => 'Default';

  @override
  String get sensFast => 'Fast';

  @override
  String get sensSlow => 'Slow';

  @override
  String get setPointerAcceleration => 'Set pointer acceleration';

  @override
  String get setTapActionOne => 'Set one-finger tap action';

  @override
  String get setTapActionThree => 'Set three-finger tap action';

  @override
  String get setTapActionTwo => 'Set two-finger tap action';

  @override
  String get setTouchpadSensitivity => 'Set touchpad sensitivity';

  @override
  String get settings => 'Settings';

  @override
  String get showMouseButtons => 'Show mouse buttons';

  @override
  String get slideNotes => 'Slide notes';

  @override
  String get statusConnectedPaired => 'Connected, paired';

  @override
  String get statusConnectedUnpaired => 'Connected, not paired';

  @override
  String get statusDiscovered => 'Discovered';

  @override
  String get statusOffline => 'Offline';

  @override
  String get statusPairRequestCheckKey => 'Pairing requested, check the key';

  @override
  String get stop => 'Stop';

  @override
  String get stopCommands => 'Stop commands';

  @override
  String get tapCommandHint => 'Tap a command below to run it.';

  @override
  String get tapLeft => 'Left click';

  @override
  String get tapMiddle => 'Middle click';

  @override
  String get tapNone => 'None';

  @override
  String get tapRight => 'Right click';

  @override
  String get textToTypeLabel => 'Text to type on the desktop';

  @override
  String get thisDevice => 'This device';

  @override
  String get touchpadHint =>
      'Drag one finger on the screen to move the mouse cursor. Tap to click, and use two or three fingers for the right and middle buttons. Use 2 fingers to scroll. Double tap to drag and drop. The gyroscope mouse can be enabled from the remote input settings';

  @override
  String get typeFieldHint => 'Typed characters are sent immediately';

  @override
  String get typeHere => 'Type here';

  @override
  String get unknownNotConnected => 'Unknown (not connected)';

  @override
  String get unknownUntilPairing => 'Unknown (appears during pairing)';

  @override
  String get unpair => 'Unpair';

  @override
  String unpairBody(String device) {
    return 'Pairing with $device will be removed and its certificate deleted from this phone. To use this device again, pairing must be repeated from scratch.';
  }

  @override
  String get unpairTitle => 'Unpair?';

  @override
  String get unpaired => 'Pairing removed.';

  @override
  String get verificationKey => 'Verification key';

  @override
  String versionLabel(String version) {
    return 'Version $version';
  }

  @override
  String get waitingForDesktop => 'Waiting to be accepted on the desktop';

  @override
  String get waitingForDesktopBody =>
      'The pairing request has been sent. Match this key with the one shown on the desktop, then tap Accept there.';

  @override
  String get waitingForPlayer =>
      'Waiting for player status from the desktop...';

  @override
  String get batteryOptimization => 'Battery optimization';

  @override
  String get batteryRestricted =>
      'The system may stop this app in the background. Allow unrestricted battery use so the connection to your devices stays alive.';

  @override
  String get batteryUnrestricted =>
      'This app can use battery without restrictions, so it stays connected in the background.';

  @override
  String get batteryAllow => 'Allow';

  @override
  String get autostart => 'Autostart (Xiaomi / HyperOS)';

  @override
  String get autostartBody =>
      'On Xiaomi phones the system also has its own Autostart switch. Turn it on for this app, or the system can stop it in the background even with unrestricted battery.';

  @override
  String get autostartOpen => 'Open';

  @override
  String get save => 'Save';

  @override
  String get add => 'Add';

  @override
  String get delete => 'Delete';

  @override
  String get deviceName => 'Device name';

  @override
  String get chooseTheme => 'Choose theme';

  @override
  String get themeSystem => 'System default';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get persistentNotification => 'Persistent notification';

  @override
  String get persistentNotificationBody =>
      'Tap to turn the persistent notification on or off in the system notification settings.';

  @override
  String get addDeviceByIp => 'Add device by IP';

  @override
  String manualDevicesCount(int count) {
    return '$count devices added manually';
  }

  @override
  String get noManualDevices => 'No devices added manually';

  @override
  String get noManualDevicesBody =>
      'Add a desktop by its IP address when discovery cannot find it, for example on a network that blocks broadcasts.';

  @override
  String get manualDeviceTapHint => 'Tap to announce to this address';

  @override
  String manualDeviceProbing(String ip) {
    return 'Announcing to $ip. A device that answers appears under Pair new device.';
  }

  @override
  String get ipAddress => 'IP address';

  @override
  String get ipAddressHint => '192.168.1.10';

  @override
  String get invalidIp => 'That does not look like a valid IP address.';

  @override
  String get exportLogs => 'Export app logs';

  @override
  String get exportLogsBody =>
      'Save the session log to a file in the received files folder, where it can help troubleshoot issues.';

  @override
  String exportLogsSaved(String path) {
    return 'Log saved to $path';
  }

  @override
  String get exportLogsFailed => 'The log could not be saved yet.';

  @override
  String get moreSettings => 'More settings';

  @override
  String get moreSettingsBody =>
      'Each device\'s own settings can be found under Plugin settings on that device\'s page.';

  @override
  String get setupTitle => 'Before you start';

  @override
  String get setupIntro =>
      'Two system switches keep HyprConnect connected in the background. Both have to be on before you can continue.';

  @override
  String get autostartConfirm => 'I have turned Autostart on for this app';

  @override
  String get setupContinue => 'Continue';

  @override
  String get checkForUpdates => 'Check for updates';

  @override
  String get updateAvailableTitle => 'A new version is available';

  @override
  String get updateDownload => 'Download';

  @override
  String get updateInstall => 'Install';

  @override
  String get updateLater => 'Later';

  @override
  String get updateDownloading => 'Downloading update…';

  @override
  String get updateUpToDate => 'You are on the latest version.';

  @override
  String get updateCheckFailed => 'Could not check for updates.';

  @override
  String get updateFailed => 'The update could not be downloaded.';

  @override
  String get updateReady => 'The update is downloaded and ready to install.';

  @override
  String get updatePermissionHint =>
      'Allow installs from this app on the settings page that opened, then come back and tap Install again.';
}

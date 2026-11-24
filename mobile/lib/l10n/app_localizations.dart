import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_id.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('id'),
  ];

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @aboutBody.
  ///
  /// In en, this message translates to:
  /// **'Companion app for the HyprConnect daemon on your desktop. It speaks the KDE Connect protocol, so it can still talk to the stock KDE Connect on desktops and other phones.'**
  String get aboutBody;

  /// No description provided for @accelHigh.
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get accelHigh;

  /// No description provided for @accelLow.
  ///
  /// In en, this message translates to:
  /// **'Low'**
  String get accelLow;

  /// No description provided for @accelMedium.
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get accelMedium;

  /// No description provided for @accelOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get accelOff;

  /// No description provided for @accept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get accept;

  /// No description provided for @addSlide.
  ///
  /// In en, this message translates to:
  /// **'Add slide'**
  String get addSlide;

  /// No description provided for @arrivesInPhase.
  ///
  /// In en, this message translates to:
  /// **'Arrives in phase {phase}'**
  String arrivesInPhase(String phase);

  /// No description provided for @automatic.
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get automatic;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @cancelRequest.
  ///
  /// In en, this message translates to:
  /// **'Cancel request'**
  String get cancelRequest;

  /// No description provided for @certFingerprint.
  ///
  /// In en, this message translates to:
  /// **'Certificate fingerprint (SHA-256)'**
  String get certFingerprint;

  /// No description provided for @clipboardEmpty.
  ///
  /// In en, this message translates to:
  /// **'Clipboard is empty or not text.'**
  String get clipboardEmpty;

  /// No description provided for @clipboardSendFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to send clipboard: {error}'**
  String clipboardSendFailed(String error);

  /// No description provided for @clipboardSent.
  ///
  /// In en, this message translates to:
  /// **'Clipboard sent'**
  String get clipboardSent;

  /// No description provided for @connect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connect;

  /// No description provided for @connectFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to connect. Check the log in Settings.'**
  String get connectFailed;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @createNotes.
  ///
  /// In en, this message translates to:
  /// **'Create notes'**
  String get createNotes;

  /// No description provided for @deviceIdLabel.
  ///
  /// In en, this message translates to:
  /// **'Device ID'**
  String get deviceIdLabel;

  /// No description provided for @deviceMenu.
  ///
  /// In en, this message translates to:
  /// **'Device menu'**
  String get deviceMenu;

  /// No description provided for @deviceOffline.
  ///
  /// In en, this message translates to:
  /// **'Device offline'**
  String get deviceOffline;

  /// No description provided for @devices.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get devices;

  /// No description provided for @doubleTapToDrag.
  ///
  /// In en, this message translates to:
  /// **'Double tap to drag'**
  String get doubleTapToDrag;

  /// No description provided for @dragAndDropBehavior.
  ///
  /// In en, this message translates to:
  /// **'Drag and drop behavior'**
  String get dragAndDropBehavior;

  /// No description provided for @editCommandsOnDesktop.
  ///
  /// In en, this message translates to:
  /// **'Edit the command list on the desktop'**
  String get editCommandsOnDesktop;

  /// No description provided for @editNotes.
  ///
  /// In en, this message translates to:
  /// **'Edit notes'**
  String get editNotes;

  /// No description provided for @enableGyroMouse.
  ///
  /// In en, this message translates to:
  /// **'Enable gyroscope mouse'**
  String get enableGyroMouse;

  /// No description provided for @encryptedConnection.
  ///
  /// In en, this message translates to:
  /// **'Encrypted connection (TLS)'**
  String get encryptedConnection;

  /// No description provided for @encryptionDisconnectedBody.
  ///
  /// In en, this message translates to:
  /// **'Connect the device first to see the encryption details of this channel.'**
  String get encryptionDisconnectedBody;

  /// No description provided for @encryptionInfo.
  ///
  /// In en, this message translates to:
  /// **'Encryption info'**
  String get encryptionInfo;

  /// No description provided for @encryptionPairedBody.
  ///
  /// In en, this message translates to:
  /// **'This device is paired. Every packet travels over TLS with self-signed certificates that were exchanged during pairing.'**
  String get encryptionPairedBody;

  /// No description provided for @encryptionUnpairedBody.
  ///
  /// In en, this message translates to:
  /// **'The TLS channel is up, but this device is not paired yet. Pair first so its certificate becomes trusted.'**
  String get encryptionUnpairedBody;

  /// No description provided for @fileSendFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to send file: {error}'**
  String fileSendFailed(String error);

  /// No description provided for @fileSent.
  ///
  /// In en, this message translates to:
  /// **'Sent: {name}'**
  String fileSent(String name);

  /// No description provided for @forward10.
  ///
  /// In en, this message translates to:
  /// **'Forward 10 seconds'**
  String get forward10;

  /// No description provided for @fullscreen.
  ///
  /// In en, this message translates to:
  /// **'Fullscreen'**
  String get fullscreen;

  /// No description provided for @functionKeys.
  ///
  /// In en, this message translates to:
  /// **'Function keys F1 to F12'**
  String get functionKeys;

  /// No description provided for @gyroSensitivity.
  ///
  /// In en, this message translates to:
  /// **'Gyroscope sensitivity'**
  String get gyroSensitivity;

  /// No description provided for @howPairingWorksBody.
  ///
  /// In en, this message translates to:
  /// **'Each device creates its own certificate, signed by no authority. Trust is built once during pairing: the verification key above is computed from both devices\' public keys, and you compare it on both sides before tapping Accept. After that the peer certificate is stored and later connections are trusted automatically.'**
  String get howPairingWorksBody;

  /// No description provided for @howPairingWorksTitle.
  ///
  /// In en, this message translates to:
  /// **'How pairing works'**
  String get howPairingWorksTitle;

  /// No description provided for @keyboard.
  ///
  /// In en, this message translates to:
  /// **'Keyboard'**
  String get keyboard;

  /// No description provided for @log.
  ///
  /// In en, this message translates to:
  /// **'Log'**
  String get log;

  /// No description provided for @menu.
  ///
  /// In en, this message translates to:
  /// **'Menu'**
  String get menu;

  /// No description provided for @next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// No description provided for @nextSlideNotes.
  ///
  /// In en, this message translates to:
  /// **'Next slide notes'**
  String get nextSlideNotes;

  /// No description provided for @noAudioDeviceFound.
  ///
  /// In en, this message translates to:
  /// **'No audio device found'**
  String get noAudioDeviceFound;

  /// No description provided for @noCommandsYet.
  ///
  /// In en, this message translates to:
  /// **'The desktop has no commands to run yet.\nAdd them through the editor on the desktop.'**
  String get noCommandsYet;

  /// No description provided for @noConnection.
  ///
  /// In en, this message translates to:
  /// **'No connection to this device.'**
  String get noConnection;

  /// No description provided for @noDeviceOnNetwork.
  ///
  /// In en, this message translates to:
  /// **'No device on this network yet'**
  String get noDeviceOnNetwork;

  /// No description provided for @noPairedDeviceBody.
  ///
  /// In en, this message translates to:
  /// **'Open the sidebar and choose Pair new device to connect your first desktop.'**
  String get noPairedDeviceBody;

  /// No description provided for @noPairedDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'No device paired yet.'**
  String get noPairedDeviceTitle;

  /// No description provided for @noPlayerFound.
  ///
  /// In en, this message translates to:
  /// **'No player found'**
  String get noPlayerFound;

  /// No description provided for @notConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get notConnected;

  /// No description provided for @notLoaded.
  ///
  /// In en, this message translates to:
  /// **'Not loaded yet'**
  String get notLoaded;

  /// No description provided for @notesHint.
  ///
  /// In en, this message translates to:
  /// **'Notes for this slide'**
  String get notesHint;

  /// No description provided for @openNotesFile.
  ///
  /// In en, this message translates to:
  /// **'Open notes file'**
  String get openNotesFile;

  /// No description provided for @openingCommandEditor.
  ///
  /// In en, this message translates to:
  /// **'Opening the command editor on the desktop'**
  String get openingCommandEditor;

  /// No description provided for @pairFirst.
  ///
  /// In en, this message translates to:
  /// **'Pair with {device} first to use {title}.'**
  String pairFirst(String device, String title);

  /// No description provided for @pairNewDevice.
  ///
  /// In en, this message translates to:
  /// **'Pair new device'**
  String get pairNewDevice;

  /// No description provided for @pairingRequest.
  ///
  /// In en, this message translates to:
  /// **'Pairing request'**
  String get pairingRequest;

  /// No description provided for @pairingRequestBody.
  ///
  /// In en, this message translates to:
  /// **'The desktop is asking to pair. Match this key with the one shown on the desktop, then tap Accept.'**
  String get pairingRequestBody;

  /// No description provided for @pasteFromClipboard.
  ///
  /// In en, this message translates to:
  /// **'Paste from clipboard'**
  String get pasteFromClipboard;

  /// No description provided for @pause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pause;

  /// No description provided for @peerDevice.
  ///
  /// In en, this message translates to:
  /// **'Peer device'**
  String get peerDevice;

  /// No description provided for @pingSent.
  ///
  /// In en, this message translates to:
  /// **'Ping sent to {name}.'**
  String pingSent(String name);

  /// No description provided for @play.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get play;

  /// No description provided for @pluginBattery.
  ///
  /// In en, this message translates to:
  /// **'Battery'**
  String get pluginBattery;

  /// No description provided for @pluginBatteryDesc.
  ///
  /// In en, this message translates to:
  /// **'Send this phone\'s battery status to the desktop.'**
  String get pluginBatteryDesc;

  /// No description provided for @pluginClipboard.
  ///
  /// In en, this message translates to:
  /// **'Clipboard'**
  String get pluginClipboard;

  /// No description provided for @pluginClipboardDesc.
  ///
  /// In en, this message translates to:
  /// **'Send and receive clipboard contents with the desktop.'**
  String get pluginClipboardDesc;

  /// No description provided for @pluginClipboardTile.
  ///
  /// In en, this message translates to:
  /// **'Send clipboard'**
  String get pluginClipboardTile;

  /// No description provided for @pluginDisabledSnack.
  ///
  /// In en, this message translates to:
  /// **'The {title} plugin is off. Enable it in Plugin settings.'**
  String pluginDisabledSnack(String title);

  /// No description provided for @pluginFindMyPhone.
  ///
  /// In en, this message translates to:
  /// **'Find my phone'**
  String get pluginFindMyPhone;

  /// No description provided for @pluginFindMyPhoneDesc.
  ///
  /// In en, this message translates to:
  /// **'Ring this phone from the desktop.'**
  String get pluginFindMyPhoneDesc;

  /// No description provided for @pluginMpris.
  ///
  /// In en, this message translates to:
  /// **'Multimedia control'**
  String get pluginMpris;

  /// No description provided for @pluginMprisDesc.
  ///
  /// In en, this message translates to:
  /// **'Play, pause, and switch tracks on the desktop.'**
  String get pluginMprisDesc;

  /// No description provided for @pluginMprisTile.
  ///
  /// In en, this message translates to:
  /// **'Multimedia control'**
  String get pluginMprisTile;

  /// No description provided for @pluginNotification.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get pluginNotification;

  /// No description provided for @pluginNotificationDesc.
  ///
  /// In en, this message translates to:
  /// **'Show desktop notifications on this phone.'**
  String get pluginNotificationDesc;

  /// No description provided for @pluginPresenter.
  ///
  /// In en, this message translates to:
  /// **'Presentation remote'**
  String get pluginPresenter;

  /// No description provided for @pluginPresenterDesc.
  ///
  /// In en, this message translates to:
  /// **'Control presentations and point with the pointer.'**
  String get pluginPresenterDesc;

  /// No description provided for @pluginPresenterTile.
  ///
  /// In en, this message translates to:
  /// **'Presentation remote'**
  String get pluginPresenterTile;

  /// No description provided for @pluginRemoteInput.
  ///
  /// In en, this message translates to:
  /// **'Remote input'**
  String get pluginRemoteInput;

  /// No description provided for @pluginRemoteInputDesc.
  ///
  /// In en, this message translates to:
  /// **'Touchpad and keyboard for the desktop.'**
  String get pluginRemoteInputDesc;

  /// No description provided for @pluginRemoteInputTile.
  ///
  /// In en, this message translates to:
  /// **'Remote input'**
  String get pluginRemoteInputTile;

  /// No description provided for @pluginRunCommand.
  ///
  /// In en, this message translates to:
  /// **'Run commands'**
  String get pluginRunCommand;

  /// No description provided for @pluginRunCommandDesc.
  ///
  /// In en, this message translates to:
  /// **'Run commands on the desktop and see their output.'**
  String get pluginRunCommandDesc;

  /// No description provided for @pluginRunCommandTile.
  ///
  /// In en, this message translates to:
  /// **'Run Commands'**
  String get pluginRunCommandTile;

  /// No description provided for @pluginSettingsHeader.
  ///
  /// In en, this message translates to:
  /// **'Plugins for {device}. Changes apply when the device reconnects.'**
  String pluginSettingsHeader(String device);

  /// No description provided for @pluginSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Plugin settings'**
  String get pluginSettingsTitle;

  /// No description provided for @pluginSftp.
  ///
  /// In en, this message translates to:
  /// **'Browse files (SFTP)'**
  String get pluginSftp;

  /// No description provided for @pluginSftpDesc.
  ///
  /// In en, this message translates to:
  /// **'Let a paired desktop browse this phone\'s files.'**
  String get pluginSftpDesc;

  /// No description provided for @sftpAccessTitle.
  ///
  /// In en, this message translates to:
  /// **'File access for browsing'**
  String get sftpAccessTitle;

  /// No description provided for @sftpAccessGranted.
  ///
  /// In en, this message translates to:
  /// **'All-files access granted, desktops can browse this phone'**
  String get sftpAccessGranted;

  /// No description provided for @sftpAccessMissing.
  ///
  /// In en, this message translates to:
  /// **'All-files access not granted, tap to allow browsing'**
  String get sftpAccessMissing;

  /// No description provided for @pluginShare.
  ///
  /// In en, this message translates to:
  /// **'Send file'**
  String get pluginShare;

  /// No description provided for @pluginShareDesc.
  ///
  /// In en, this message translates to:
  /// **'Send files to the desktop and receive files from it.'**
  String get pluginShareDesc;

  /// No description provided for @pluginShareTile.
  ///
  /// In en, this message translates to:
  /// **'Send file'**
  String get pluginShareTile;

  /// No description provided for @pluginSystemVolume.
  ///
  /// In en, this message translates to:
  /// **'System volume'**
  String get pluginSystemVolume;

  /// No description provided for @pluginSystemVolumeDesc.
  ///
  /// In en, this message translates to:
  /// **'Control the desktop speaker volume.'**
  String get pluginSystemVolumeDesc;

  /// No description provided for @previous.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get previous;

  /// No description provided for @previousSlideNotes.
  ///
  /// In en, this message translates to:
  /// **'Previous slide notes'**
  String get previousSlideNotes;

  /// No description provided for @receivedFilesFolder.
  ///
  /// In en, this message translates to:
  /// **'Received files folder'**
  String get receivedFilesFolder;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @reject.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get reject;

  /// No description provided for @reloadList.
  ///
  /// In en, this message translates to:
  /// **'Reload list'**
  String get reloadList;

  /// No description provided for @remoteInputSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Remote Input settings'**
  String get remoteInputSettingsTitle;

  /// No description provided for @requestPairing.
  ///
  /// In en, this message translates to:
  /// **'Request pairing'**
  String get requestPairing;

  /// No description provided for @reverseScrollDirection.
  ///
  /// In en, this message translates to:
  /// **'Reverse scroll direction'**
  String get reverseScrollDirection;

  /// No description provided for @rewind10.
  ///
  /// In en, this message translates to:
  /// **'Back 10 seconds'**
  String get rewind10;

  /// No description provided for @sameWifiHint.
  ///
  /// In en, this message translates to:
  /// **'Make sure the desktop and this phone are on the same Wi-Fi.'**
  String get sameWifiHint;

  /// No description provided for @scrollSensitivity.
  ///
  /// In en, this message translates to:
  /// **'Scroll sensitivity'**
  String get scrollSensitivity;

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @sendPing.
  ///
  /// In en, this message translates to:
  /// **'Send ping'**
  String get sendPing;

  /// No description provided for @sendText.
  ///
  /// In en, this message translates to:
  /// **'Send text'**
  String get sendText;

  /// No description provided for @sendingFile.
  ///
  /// In en, this message translates to:
  /// **'Sending file'**
  String get sendingFile;

  /// No description provided for @sensDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get sensDefault;

  /// No description provided for @sensFast.
  ///
  /// In en, this message translates to:
  /// **'Fast'**
  String get sensFast;

  /// No description provided for @sensSlow.
  ///
  /// In en, this message translates to:
  /// **'Slow'**
  String get sensSlow;

  /// No description provided for @setPointerAcceleration.
  ///
  /// In en, this message translates to:
  /// **'Set pointer acceleration'**
  String get setPointerAcceleration;

  /// No description provided for @setTapActionOne.
  ///
  /// In en, this message translates to:
  /// **'Set one-finger tap action'**
  String get setTapActionOne;

  /// No description provided for @setTapActionThree.
  ///
  /// In en, this message translates to:
  /// **'Set three-finger tap action'**
  String get setTapActionThree;

  /// No description provided for @setTapActionTwo.
  ///
  /// In en, this message translates to:
  /// **'Set two-finger tap action'**
  String get setTapActionTwo;

  /// No description provided for @setTouchpadSensitivity.
  ///
  /// In en, this message translates to:
  /// **'Set touchpad sensitivity'**
  String get setTouchpadSensitivity;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @showMouseButtons.
  ///
  /// In en, this message translates to:
  /// **'Show mouse buttons'**
  String get showMouseButtons;

  /// No description provided for @slideNotes.
  ///
  /// In en, this message translates to:
  /// **'Slide notes'**
  String get slideNotes;

  /// No description provided for @statusConnectedPaired.
  ///
  /// In en, this message translates to:
  /// **'Connected, paired'**
  String get statusConnectedPaired;

  /// No description provided for @statusConnectedUnpaired.
  ///
  /// In en, this message translates to:
  /// **'Connected, not paired'**
  String get statusConnectedUnpaired;

  /// No description provided for @statusDiscovered.
  ///
  /// In en, this message translates to:
  /// **'Discovered'**
  String get statusDiscovered;

  /// No description provided for @statusOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get statusOffline;

  /// No description provided for @statusPairRequestCheckKey.
  ///
  /// In en, this message translates to:
  /// **'Pairing requested, check the key'**
  String get statusPairRequestCheckKey;

  /// No description provided for @stop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get stop;

  /// No description provided for @stopCommands.
  ///
  /// In en, this message translates to:
  /// **'Stop commands'**
  String get stopCommands;

  /// No description provided for @tapCommandHint.
  ///
  /// In en, this message translates to:
  /// **'Tap a command below to run it.'**
  String get tapCommandHint;

  /// No description provided for @tapLeft.
  ///
  /// In en, this message translates to:
  /// **'Left click'**
  String get tapLeft;

  /// No description provided for @tapMiddle.
  ///
  /// In en, this message translates to:
  /// **'Middle click'**
  String get tapMiddle;

  /// No description provided for @tapNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get tapNone;

  /// No description provided for @tapRight.
  ///
  /// In en, this message translates to:
  /// **'Right click'**
  String get tapRight;

  /// No description provided for @textToTypeLabel.
  ///
  /// In en, this message translates to:
  /// **'Text to type on the desktop'**
  String get textToTypeLabel;

  /// No description provided for @thisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get thisDevice;

  /// No description provided for @touchpadHint.
  ///
  /// In en, this message translates to:
  /// **'Drag one finger on the screen to move the mouse cursor. Tap to click, and use two or three fingers for the right and middle buttons. Use 2 fingers to scroll. Double tap to drag and drop. The gyroscope mouse can be enabled from the remote input settings'**
  String get touchpadHint;

  /// No description provided for @typeFieldHint.
  ///
  /// In en, this message translates to:
  /// **'Typed characters are sent immediately'**
  String get typeFieldHint;

  /// No description provided for @typeHere.
  ///
  /// In en, this message translates to:
  /// **'Type here'**
  String get typeHere;

  /// No description provided for @unknownNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Unknown (not connected)'**
  String get unknownNotConnected;

  /// No description provided for @unknownUntilPairing.
  ///
  /// In en, this message translates to:
  /// **'Unknown (appears during pairing)'**
  String get unknownUntilPairing;

  /// No description provided for @unpair.
  ///
  /// In en, this message translates to:
  /// **'Unpair'**
  String get unpair;

  /// No description provided for @unpairBody.
  ///
  /// In en, this message translates to:
  /// **'Pairing with {device} will be removed and its certificate deleted from this phone. To use this device again, pairing must be repeated from scratch.'**
  String unpairBody(String device);

  /// No description provided for @unpairTitle.
  ///
  /// In en, this message translates to:
  /// **'Unpair?'**
  String get unpairTitle;

  /// No description provided for @unpaired.
  ///
  /// In en, this message translates to:
  /// **'Pairing removed.'**
  String get unpaired;

  /// No description provided for @verificationKey.
  ///
  /// In en, this message translates to:
  /// **'Verification key'**
  String get verificationKey;

  /// No description provided for @versionLabel.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String versionLabel(String version);

  /// No description provided for @waitingForDesktop.
  ///
  /// In en, this message translates to:
  /// **'Waiting to be accepted on the desktop'**
  String get waitingForDesktop;

  /// No description provided for @waitingForDesktopBody.
  ///
  /// In en, this message translates to:
  /// **'The pairing request has been sent. Match this key with the one shown on the desktop, then tap Accept there.'**
  String get waitingForDesktopBody;

  /// No description provided for @waitingForPlayer.
  ///
  /// In en, this message translates to:
  /// **'Waiting for player status from the desktop...'**
  String get waitingForPlayer;

  /// No description provided for @batteryOptimization.
  ///
  /// In en, this message translates to:
  /// **'Battery optimization'**
  String get batteryOptimization;

  /// No description provided for @batteryRestricted.
  ///
  /// In en, this message translates to:
  /// **'The system may stop this app in the background. Allow unrestricted battery use so the connection to your devices stays alive.'**
  String get batteryRestricted;

  /// No description provided for @batteryUnrestricted.
  ///
  /// In en, this message translates to:
  /// **'This app can use battery without restrictions, so it stays connected in the background.'**
  String get batteryUnrestricted;

  /// No description provided for @batteryAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get batteryAllow;

  /// No description provided for @autostart.
  ///
  /// In en, this message translates to:
  /// **'Autostart (Xiaomi / HyperOS)'**
  String get autostart;

  /// No description provided for @autostartBody.
  ///
  /// In en, this message translates to:
  /// **'On Xiaomi phones the system also has its own Autostart switch. Turn it on for this app, or the system can stop it in the background even with unrestricted battery.'**
  String get autostartBody;

  /// No description provided for @autostartOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get autostartOpen;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @deviceName.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get deviceName;

  /// No description provided for @chooseTheme.
  ///
  /// In en, this message translates to:
  /// **'Choose theme'**
  String get chooseTheme;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @persistentNotification.
  ///
  /// In en, this message translates to:
  /// **'Persistent notification'**
  String get persistentNotification;

  /// No description provided for @persistentNotificationBody.
  ///
  /// In en, this message translates to:
  /// **'Tap to turn the persistent notification on or off in the system notification settings.'**
  String get persistentNotificationBody;

  /// No description provided for @addDeviceByIp.
  ///
  /// In en, this message translates to:
  /// **'Add device by IP'**
  String get addDeviceByIp;

  /// No description provided for @manualDevicesCount.
  ///
  /// In en, this message translates to:
  /// **'{count} devices added manually'**
  String manualDevicesCount(int count);

  /// No description provided for @noManualDevices.
  ///
  /// In en, this message translates to:
  /// **'No devices added manually'**
  String get noManualDevices;

  /// No description provided for @noManualDevicesBody.
  ///
  /// In en, this message translates to:
  /// **'Add a desktop by its IP address when discovery cannot find it, for example on a network that blocks broadcasts.'**
  String get noManualDevicesBody;

  /// No description provided for @manualDeviceTapHint.
  ///
  /// In en, this message translates to:
  /// **'Tap to announce to this address'**
  String get manualDeviceTapHint;

  /// No description provided for @manualDeviceProbing.
  ///
  /// In en, this message translates to:
  /// **'Announcing to {ip}. A device that answers appears under Pair new device.'**
  String manualDeviceProbing(String ip);

  /// No description provided for @ipAddress.
  ///
  /// In en, this message translates to:
  /// **'IP address'**
  String get ipAddress;

  /// No description provided for @ipAddressHint.
  ///
  /// In en, this message translates to:
  /// **'192.168.1.10'**
  String get ipAddressHint;

  /// No description provided for @invalidIp.
  ///
  /// In en, this message translates to:
  /// **'That does not look like a valid IP address.'**
  String get invalidIp;

  /// No description provided for @exportLogs.
  ///
  /// In en, this message translates to:
  /// **'Export app logs'**
  String get exportLogs;

  /// No description provided for @exportLogsBody.
  ///
  /// In en, this message translates to:
  /// **'Save the session log to a file in the received files folder, where it can help troubleshoot issues.'**
  String get exportLogsBody;

  /// No description provided for @exportLogsSaved.
  ///
  /// In en, this message translates to:
  /// **'Log saved to {path}'**
  String exportLogsSaved(String path);

  /// No description provided for @exportLogsFailed.
  ///
  /// In en, this message translates to:
  /// **'The log could not be saved yet.'**
  String get exportLogsFailed;

  /// No description provided for @moreSettings.
  ///
  /// In en, this message translates to:
  /// **'More settings'**
  String get moreSettings;

  /// No description provided for @moreSettingsBody.
  ///
  /// In en, this message translates to:
  /// **'Each device\'s own settings can be found under Plugin settings on that device\'s page.'**
  String get moreSettingsBody;

  /// No description provided for @setupTitle.
  ///
  /// In en, this message translates to:
  /// **'Before you start'**
  String get setupTitle;

  /// No description provided for @setupIntro.
  ///
  /// In en, this message translates to:
  /// **'Two system switches keep HyprConnect connected in the background. Both have to be on before you can continue.'**
  String get setupIntro;

  /// No description provided for @autostartConfirm.
  ///
  /// In en, this message translates to:
  /// **'I have turned Autostart on for this app'**
  String get autostartConfirm;

  /// No description provided for @setupContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get setupContinue;

  /// No description provided for @checkForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get checkForUpdates;

  /// No description provided for @updateAvailableTitle.
  ///
  /// In en, this message translates to:
  /// **'A new version is available'**
  String get updateAvailableTitle;

  /// No description provided for @updateDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get updateDownload;

  /// No description provided for @updateInstall.
  ///
  /// In en, this message translates to:
  /// **'Install'**
  String get updateInstall;

  /// No description provided for @updateLater.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get updateLater;

  /// No description provided for @updateDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading update…'**
  String get updateDownloading;

  /// No description provided for @updateUpToDate.
  ///
  /// In en, this message translates to:
  /// **'You are on the latest version.'**
  String get updateUpToDate;

  /// No description provided for @updateCheckFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not check for updates.'**
  String get updateCheckFailed;

  /// No description provided for @updateFailed.
  ///
  /// In en, this message translates to:
  /// **'The update could not be downloaded.'**
  String get updateFailed;

  /// No description provided for @updateReady.
  ///
  /// In en, this message translates to:
  /// **'The update is downloaded and ready to install.'**
  String get updateReady;

  /// No description provided for @updatePermissionHint.
  ///
  /// In en, this message translates to:
  /// **'Allow installs from this app on the settings page that opened, then come back and tap Install again.'**
  String get updatePermissionHint;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'id'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'id':
      return AppLocalizationsId();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}

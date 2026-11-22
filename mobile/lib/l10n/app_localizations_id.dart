// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Indonesian (`id`).
class AppLocalizationsId extends AppLocalizations {
  AppLocalizationsId([String locale = 'id']) : super(locale);

  @override
  String get about => 'Tentang';

  @override
  String get aboutBody =>
      'Aplikasi pendamping daemon HyprConnect di desktop. Memakai protokol KDE Connect, jadi tetap bisa berkomunikasi dengan KDE Connect bawaan di desktop maupun HP lain.';

  @override
  String get accelHigh => 'Tinggi';

  @override
  String get accelLow => 'Rendah';

  @override
  String get accelMedium => 'Menengah';

  @override
  String get accelOff => 'Mati';

  @override
  String get accept => 'Terima';

  @override
  String get addSlide => 'Tambah slide';

  @override
  String arrivesInPhase(String phase) {
    return 'Hadir di fase $phase';
  }

  @override
  String get automatic => 'Otomatis';

  @override
  String get back => 'Kembali';

  @override
  String get cancel => 'Batal';

  @override
  String get cancelRequest => 'Batalkan permintaan';

  @override
  String get certFingerprint => 'Sidik jari sertifikat (SHA-256)';

  @override
  String get clipboardEmpty => 'Papan klip kosong atau bukan teks.';

  @override
  String clipboardSendFailed(String error) {
    return 'Gagal mengirim papan klip: $error';
  }

  @override
  String get clipboardSent => 'Papan klip terkirim';

  @override
  String get connect => 'Hubungkan';

  @override
  String get connectFailed => 'Gagal terhubung. Cek log di Pengaturan.';

  @override
  String get copy => 'Salin';

  @override
  String get createNotes => 'Buat catatan';

  @override
  String get deviceIdLabel => 'ID perangkat';

  @override
  String get deviceMenu => 'Menu perangkat';

  @override
  String get deviceOffline => 'Perangkat luring';

  @override
  String get devices => 'Peranti';

  @override
  String get doubleTapToDrag => 'Ketuk dua kali untuk drag';

  @override
  String get dragAndDropBehavior => 'Drag and drop behavior';

  @override
  String get editCommandsOnDesktop => 'Ubah daftar perintah di desktop';

  @override
  String get editNotes => 'Ubah catatan';

  @override
  String get enableGyroMouse => 'Aktifkan tetikus giroskop';

  @override
  String get encryptedConnection => 'Koneksi terenkripsi (TLS)';

  @override
  String get encryptionDisconnectedBody =>
      'Hubungkan perangkat dulu untuk melihat detail enkripsi kanal ini.';

  @override
  String get encryptionInfo => 'Info Enkripsi';

  @override
  String get encryptionPairedBody =>
      'Perangkat ini sudah dipair. Semua paket berjalan di atas TLS dengan sertifikat self-signed yang saling dikenali saat pairing.';

  @override
  String get encryptionUnpairedBody =>
      'Kanal TLS sudah naik, tapi perangkat ini belum dipair. Pair dulu supaya sertifikatnya dipercaya.';

  @override
  String fileSendFailed(String error) {
    return 'Gagal mengirim file: $error';
  }

  @override
  String fileSent(String name) {
    return 'Terkirim: $name';
  }

  @override
  String get forward10 => 'Maju 10 detik';

  @override
  String get fullscreen => 'Layar penuh';

  @override
  String get functionKeys => 'Tombol fungsi F1 sampai F12';

  @override
  String get gyroSensitivity => 'Sensitivitas giroskop';

  @override
  String get howPairingWorksBody =>
      'Sertifikat dibuat sendiri oleh tiap perangkat dan tidak ditandatangani otoritas mana pun. Kepercayaan dibangun sekali saat pairing: kunci verifikasi di atas dihitung dari kunci publik kedua perangkat, dan kamu membandingkannya di kedua sisi sebelum menekan Terima. Setelah itu sertifikat lawan disimpan dan koneksi berikutnya otomatis terpercaya.';

  @override
  String get howPairingWorksTitle => 'Cara kerja pairing';

  @override
  String get keyboard => 'Keyboard';

  @override
  String get log => 'Log';

  @override
  String get menu => 'Menu';

  @override
  String get next => 'Berikutnya';

  @override
  String get nextSlideNotes => 'Catatan slide berikutnya';

  @override
  String get noAudioDeviceFound => 'Tidak ada perangkat audio yang ditemukan';

  @override
  String get noCommandsYet =>
      'Desktop belum punya perintah yang bisa dijalankan.\nTambah lewat editor di desktop.';

  @override
  String get noConnection => 'Tidak ada koneksi ke perangkat ini.';

  @override
  String get noDeviceOnNetwork => 'Belum ada perangkat di jaringan ini';

  @override
  String get noPairedDeviceBody =>
      'Buka sidebar lalu pilih Sandingkan peranti baru untuk menghubungkan desktop pertamamu.';

  @override
  String get noPairedDeviceTitle => 'Belum ada peranti yang disandingkan.';

  @override
  String get noPlayerFound => 'Tidak ada pemutar yang ditemukan';

  @override
  String get notConnected => 'Belum terhubung';

  @override
  String get notLoaded => 'Belum dimuat';

  @override
  String get notesHint => 'Catatan untuk slide ini';

  @override
  String get openNotesFile => 'Buka file catatan';

  @override
  String get openingCommandEditor => 'Membuka editor perintah di desktop';

  @override
  String pairFirst(String device, String title) {
    return 'Pair dulu dengan $device untuk memakai $title.';
  }

  @override
  String get pairNewDevice => 'Sandingkan peranti baru';

  @override
  String get pairingRequest => 'Permintaan pairing';

  @override
  String get pairingRequestBody =>
      'Desktop meminta pairing. Cocokkan kunci ini dengan yang tampil di desktop, lalu tekan Terima.';

  @override
  String get pasteFromClipboard => 'Tempel dari papan klip';

  @override
  String get pause => 'Jeda';

  @override
  String get peerDevice => 'Perangkat lawan';

  @override
  String pingSent(String name) {
    return 'Ping terkirim ke $name.';
  }

  @override
  String get play => 'Putar';

  @override
  String get pluginBattery => 'Baterai';

  @override
  String get pluginBatteryDesc => 'Kirim status baterai HP ke desktop.';

  @override
  String get pluginClipboard => 'Papan klip';

  @override
  String get pluginClipboardDesc =>
      'Kirim dan terima isi papan klip dengan desktop.';

  @override
  String get pluginClipboardTile => 'Kirim papan klip';

  @override
  String pluginDisabledSnack(String title) {
    return 'Plugin $title nonaktif. Aktifkan di Pengesetan plugin.';
  }

  @override
  String get pluginFindMyPhone => 'Cari HP';

  @override
  String get pluginFindMyPhoneDesc => 'Bunyikan HP dari desktop.';

  @override
  String get pluginMpris => 'Kendali multimedia';

  @override
  String get pluginMprisDesc => 'Putar, jeda, dan ganti lagu di desktop.';

  @override
  String get pluginMprisTile => 'Kendali multimedia';

  @override
  String get pluginNotification => 'Notifikasi';

  @override
  String get pluginNotificationDesc => 'Tampilkan notifikasi desktop di HP.';

  @override
  String get pluginPresenter => 'Presentation remote';

  @override
  String get pluginPresenterDesc =>
      'Kendalikan presentasi dan arahkan pointer.';

  @override
  String get pluginPresenterTile => 'Presentation remote';

  @override
  String get pluginRemoteInput => 'Masukan jarak jauh';

  @override
  String get pluginRemoteInputDesc => 'Touchpad dan keyboard untuk desktop.';

  @override
  String get pluginRemoteInputTile => 'Masukan jarak jauh';

  @override
  String get pluginRunCommand => 'Jalankan perintah';

  @override
  String get pluginRunCommandDesc =>
      'Jalankan perintah di desktop dan lihat hasilnya.';

  @override
  String get pluginRunCommandTile => 'Jalankan Perintah';

  @override
  String pluginSettingsHeader(String device) {
    return 'Plugin untuk $device. Perubahan berlaku saat perangkat terhubung ulang.';
  }

  @override
  String get pluginSettingsTitle => 'Pengesetan plugin';

  @override
  String get pluginSftp => 'Jelajah file (SFTP)';

  @override
  String get pluginSftpDesc => 'Akses file desktop lewat SFTP.';

  @override
  String get pluginShare => 'Kirim file';

  @override
  String get pluginShareDesc =>
      'Kirim file ke desktop dan terima file darinya.';

  @override
  String get pluginShareTile => 'Kirim file';

  @override
  String get pluginSystemVolume => 'Volume sistem';

  @override
  String get pluginSystemVolumeDesc => 'Atur volume speaker desktop.';

  @override
  String get previous => 'Sebelumnya';

  @override
  String get previousSlideNotes => 'Catatan slide sebelumnya';

  @override
  String get receivedFilesFolder => 'Folder file diterima';

  @override
  String get refresh => 'Muat ulang';

  @override
  String get reject => 'Tolak';

  @override
  String get reloadList => 'Muat ulang daftar';

  @override
  String get remoteInputSettingsTitle => 'Pengaturan Masukan jarak jauh';

  @override
  String get requestPairing => 'Minta pairing';

  @override
  String get reverseScrollDirection => 'Arah Menggulir Terbalik';

  @override
  String get rewind10 => 'Mundur 10 detik';

  @override
  String get sameWifiHint =>
      'Pastikan desktop dan HP berada di Wi-Fi yang sama.';

  @override
  String get scrollSensitivity => 'Sensitivitas gulir';

  @override
  String get send => 'Kirim';

  @override
  String get sendPing => 'Kirim ping';

  @override
  String get sendText => 'Kirim teks';

  @override
  String get sendingFile => 'Mengirim file';

  @override
  String get sensDefault => 'Bawaan';

  @override
  String get sensFast => 'Cepat';

  @override
  String get sensSlow => 'Pelan';

  @override
  String get setPointerAcceleration => 'Setel akselerasi pointer';

  @override
  String get setTapActionOne => 'Setel aksi ketuk satu jari';

  @override
  String get setTapActionThree => 'Setel aksi ketuk tiga jari';

  @override
  String get setTapActionTwo => 'Setel aksi ketuk dua jari';

  @override
  String get setTouchpadSensitivity => 'Setel kepekaan touchpad';

  @override
  String get settings => 'Pengaturan';

  @override
  String get showMouseButtons => 'Tampilkan tombol tetikus';

  @override
  String get slideNotes => 'Catatan slide';

  @override
  String get statusConnectedPaired => 'Terhubung, paired';

  @override
  String get statusConnectedUnpaired => 'Terhubung, belum dipair';

  @override
  String get statusDiscovered => 'Ditemukan';

  @override
  String get statusOffline => 'Luring';

  @override
  String get statusPairRequestCheckKey => 'Minta pairing, cek kunci';

  @override
  String get stop => 'Berhenti';

  @override
  String get stopCommands => 'Hentikan perintah';

  @override
  String get tapCommandHint => 'Ketuk perintah di bawah untuk menjalankannya.';

  @override
  String get tapLeft => 'Klik kiri';

  @override
  String get tapMiddle => 'Klik tengah';

  @override
  String get tapNone => 'Tidak ada';

  @override
  String get tapRight => 'Klik kanan';

  @override
  String get textToTypeLabel => 'Teks yang akan diketik di desktop';

  @override
  String get thisDevice => 'Perangkat ini';

  @override
  String get touchpadHint =>
      'Geser satu jari di layar untuk menggerakkan kursor mouse. Ketuk untuk klik, dan gunakan dua atau tiga jari untuk tombol kanan dan tengah. Gunakan 2 jari untuk menggulir. Ketuk dua kali untuk drag and drop. Tetikus giroskop dapat diaktifkan dari pengaturan masukan jarak jauh';

  @override
  String get typeFieldHint => 'Huruf yang diketik langsung terkirim';

  @override
  String get typeHere => 'Ketik di sini';

  @override
  String get unknownNotConnected => 'Belum diketahui (belum terhubung)';

  @override
  String get unknownUntilPairing => 'Belum diketahui (muncul saat pairing)';

  @override
  String get unpair => 'Leraikan';

  @override
  String unpairBody(String device) {
    return 'Pairing dengan $device akan dilepas dan sertifikatnya dihapus dari HP ini. Untuk memakai perangkat ini lagi, pairing harus diulang dari awal.';
  }

  @override
  String get unpairTitle => 'Leraikan pairing?';

  @override
  String get unpaired => 'Pairing dilepas.';

  @override
  String get verificationKey => 'Kunci verifikasi';

  @override
  String versionLabel(String version) {
    return 'Versi $version';
  }

  @override
  String get waitingForDesktop => 'Menunggu diterima di desktop';

  @override
  String get waitingForDesktopBody =>
      'Permintaan pairing sudah terkirim. Cocokkan kunci ini dengan yang tampil di desktop, lalu tekan Terima di sana.';

  @override
  String get waitingForPlayer => 'Menunggu status player dari desktop...';

  @override
  String get batteryOptimization => 'Optimasi baterai';

  @override
  String get batteryRestricted =>
      'Sistem dapat menghentikan aplikasi ini di latar. Izinkan pemakaian baterai tanpa batas agar koneksi ke perangkatmu tetap hidup.';

  @override
  String get batteryUnrestricted =>
      'Aplikasi ini dapat memakai baterai tanpa batas, jadi tetap terhubung di latar.';

  @override
  String get batteryAllow => 'Izinkan';

  @override
  String get autostart => 'Autostart (Xiaomi / HyperOS)';

  @override
  String get autostartBody =>
      'Di HP Xiaomi sistem juga punya saklar Autostart sendiri. Nyalakan untuk aplikasi ini, atau sistem bisa menghentikannya di latar walau baterai sudah tanpa batas.';

  @override
  String get autostartOpen => 'Buka';
}

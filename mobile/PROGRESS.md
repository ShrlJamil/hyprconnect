# HyprConnect mobile (Flutter) — build progress

Autonomous build session ordered by Sahrul on 2026-11-22, time-boxed until
17:00 WIB the same day. Target: phases M0 through M5. Quality over speed.

## Hard constraints

- STOCK KDE CONNECT COMPATIBILITY IS MANDATORY. The daemon must keep
  working with the stock KDE Connect Android app exactly as it does today:
  daemon changes are purely additive (new optional fields or packet
  handling that stock clients ignore); never rename, remove, or alter
  existing packets, capabilities, or behaviour. The Flutter app speaks the
  standard protocol for every core feature so it can also pair with a
  stock kdeconnectd desktop; the HyprPresenter extras (monitor list and
  selection) degrade gracefully when the desktop never answers them.
- Protocol ground truth is the daemon source in this repo (src/main.rs,
  src/packet.rs). Read it before implementing any packet; never guess.
  Reference clones also exist on the VM at ~/workspace/ref-kdeconnect-kde
  and ~/workspace/ref-kdeconnect-android.
- Git: commit locally when a phase completes, clear message. NEVER push.
  No secrets or runtime state in the repo; the app's identity key and
  certificate are generated and kept in app-private storage at runtime.
- No system package installs on the laptop. flutter pub add/get of public
  pub.dev packages is fine.
- Verification per phase: `flutter analyze` clean and
  `flutter build apk --debug` succeeds; record the evidence here.

## Environment

- Laptop arch-acer, repo ~/Documents/DEV/hyprconnect, app in mobile/.
- Flutter 3.47.5 at ~/Development/flutter/bin (export PATH first).
- applicationId io.github.shrljamil.hyprconnect, label HyprConnect.
- Daemon: systemd user service hyprconnect.service, TCP 1714, discovery
  UDP 1716. Restart only via the compositor if ever needed.

## Phases

- [x] M0 Protocol foundation: persistent device identity (deviceId plus
      RSA 2048 self-signed certificate, CN = deviceId), UDP discovery
      listen and broadcast, TCP connect and listen, plaintext identity
      exchange then TLS in both roles (opener is TLS server, receiver is
      TLS client), newline-delimited JSON packet framing, pairing with
      verification key computed exactly like the daemon, trusted-device
      storage, ping round-trip against the real daemon.
      SELESAI 2026-11-22 13:21. Bukti: `flutter test` 11/11 lolos
      (packet 4, identity 5, TLS dua peran + pairing 1, interop 1);
      `flutter analyze` bersih; `flutter build apk --debug` berhasil
      (mobile/build/app/outputs/flutter-apk/app-debug.apk, 156 MB).
      Bukti hidup dari log daemon: `pairing completed with
      6058b03b38b11c75fa3cb5006e599931`, `ping from 6058b03b...: M0
      interop masuk` (saluran daemon->HP) dan `...: M0 interop keluar`
      (saluran HP->daemon); kunci verifikasi app sama dengan yang
      dihitung daemon di snapshot `hyprconnect devices`.
      Catatan penting: server TLS Dart hanya menerima client cert
      yang ada di trusted certificates-nya (terbukti lewat probe:
      setTrustedCertificatesBytes = cert peer berhasil, tanpa itu
      gagal CERTIFICATE_VERIFY_FAILED). Akibatnya peran opener (HP
      sebagai TLS server) butuh cert desktop yang sudah dikenal dari
      trust store; pairing PERTAMA dengan desktop yang belum pernah
      dikenal harus dimulai dari desktop (`hyprconnect pair <id>`),
      setelah itu HP bisa membuka koneksi sendiri. Aturan ini
      didokumentasikan di lib/src/protocol/connection.dart dan di UI
      (dialog 'Pairing pertama'). Bug yang ditemukan dan diperbaiki
      saat tes interop: TcpListener memakai broadcast stream yang
      membuang koneksi yang datang sebelum ada yang mendengarkan —
      kini single-subscription (buffered).
- [x] M1 KDE Connect-style shell: device list, device page with the
      two-column tile grid (Kirim file, Kirim papan klip, Presentation
      remote, Kendali multimedia, Masukan jarak jauh, Jalankan Perintah),
      three-dot menu (Kirim ping, Pengesetan plugin, Info Enkripsi,
      Leraikan), plugin settings page, encryption info page.
      SELESAI 2026-11-22 13:35. Bukti: `flutter test` 24/24 lolos
      (M0 11 + plugin settings 5 + packet filter 2 + unpair 1 +
      widget halaman perangkat 5); `flutter analyze` bersih;
      `flutter build apk --debug` berhasil
      (mobile/build/app/outputs/flutter-apk/app-debug.apk, 176 MB).
      Halaman utama kini menampilkan perangkat yang pernah dipair
      walau sedang luring; halaman perangkat memakai AppState bersama
      sehingga status pairing/koneksi berubah di semua halaman
      sekaligus. Pengaturan plugin per perangkat tersimpan di
      plugin_settings.json (11 plugin, urutan dan id sama seperti
      PLUGIN_NAMES daemon) dan ikut menyaring capability di identity
      paket per koneksi, persis seperti filter disabled_plugins
      daemon; broadcast discovery tetap mengiklankan daftar penuh.
      Ubin yang fiturnya baru hadir di M2-M5 membuka halaman
      placeholder jujur yang menyebut fasenya; ubin yang pluginnya
      dimatikan menjelaskan cara mengaktifkannya lagi. Unpair
      (pair:false) terbukti dua arah di tes TLS: kedua sisi lupa trust.
      Daemon TIDAK diubah sama sekali di fase ini; tes interop M0
      tetap lolos melawan daemon yang sedang jalan (systemd active,
      port 1714 listen).
- [ ] M2 Send file (share.request with payload upload) and Send clipboard
      (clipboard push; receive sets the phone clipboard), within Android
      limits.
- [ ] M3 Multimedia control (control the desktop players from the phone)
      and Run commands (list, run, streamed output).
- [ ] M4 Remote input: touchpad and keyboard to the desktop
      (kdeconnect.mousepad.request, same semantics as the daemon already
      implements for the stock app).
- [ ] M5 Presentation remote with HyprPresenter parity: gyro and drag
      pointer (kdeconnect.presenter), next/previous, monitor selection
      (additive daemon extension: the app may ask for the monitor list
      and set the presenter monitor; stock clients unaffected), presenter
      notes stored locally on the phone and shown on the presenter
      screen.

## Log

- 2026-11-22 12:46 Scaffold created with flutter create
  (org io.github.shrljamil, platforms android). Nothing else yet.
- 2026-11-22 13:21 M0 selesai (lihat centang di atas). File protokol di
  mobile/lib/src/protocol/ (packet, der, identity, trust_store,
  discovery, listener, connection). UI M0 minimal di lib/main.dart
  (identitas, daftar discovery, connect/pair/ping, log). Tes di
  mobile/test/ (packet_test, identity_test, tls_test, interop_test).
  Izin INTERNET/ACCESS_NETWORK_STATE/ACCESS_WIFI_STATE ditambahkan ke
  AndroidManifest. test/widget_test.dart scaffold dihapus.
- 2026-11-22 13:35 M1 selesai (lihat centang di atas). File baru:
  mobile/lib/src/settings/plugin_settings.dart (katalog 11 plugin +
  simpan per perangkat), mobile/lib/src/ui/app_state.dart (state
  bersama + DeviceListEntry + ConnectOutcome),
  mobile/lib/src/ui/device_page.dart (grid 6 ubin + menu titik tiga
  + spanduk pairing dengan kunci verifikasi + dialog pairing
  pertama + konfirmasi leraikan),
  mobile/lib/src/ui/plugin_settings_page.dart,
  mobile/lib/src/ui/encryption_info_page.dart (sidik jari SHA-256
  kedua sertifikat + kunci verifikasi),
  mobile/lib/src/ui/feature_placeholder_page.dart.
  Perubahan protokol aditif saja: Packet.identity menerima
  disabledPlugins (default kosong, paket tak berubah),
  DeviceConnection.unpair()/rejectPair() (pair:false, sudah dikenal
  daemon). Tes baru: test/plugin_settings_test.dart,
  test/device_page_test.dart; packet_test dan tls_test diperluas.
- Next step: M2 — Kirim file (share.request + upload payload) dan
  Kirim papan klip (clipboard push; terima mengatur papan klip HP),
  dalam batas Android.

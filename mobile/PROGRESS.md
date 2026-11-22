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
- [ ] M1 KDE Connect-style shell: device list, device page with the
      two-column tile grid (Kirim file, Kirim papan klip, Presentation
      remote, Kendali multimedia, Masukan jarak jauh, Jalankan Perintah),
      three-dot menu (Kirim ping, Pengesetan plugin, Info Enkripsi,
      Leraikan), plugin settings page, encryption info page.
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
- Next step: M1 — shell ala KDE Connect (daftar perangkat, halaman
  perangkat grid dua kolom 6 ubin, menu titik tiga, halaman pengaturan
  plugin, halaman info enkripsi).

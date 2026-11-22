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
- [x] M2 Send file (share.request with payload upload) and Send clipboard
      (clipboard push; receive sets the phone clipboard), within Android
      limits.
      SELESAI 2026-11-22 14:15. Bukti: `flutter test --concurrency=1`
      32/32 lolos (M0 11 + M1 13 + M2 7 baru + interop M0 1);
      `flutter analyze` bersih; `flutter build apk --debug` berhasil
      (mobile/build/app/outputs/flutter-apk/app-debug.apk, 181 MB).
      Bukti hidup dari log daemon (14:14:33-34): `clipboard received
      (21 chars), applying`, `received m2-interop-...txt (42 bytes) ->
      ~/Downloads/...`, `offered m2-daemon-file.txt (40 bytes)` +
      `sent ... (40 bytes)`, `local clipboard changed (23 chars),
      forwarding to 2 device(s)` — keempat arah (kirim/terima file dan
      papan klip) terbukti melawan daemon yang sedang jalan.
      Daemon TIDAK diubah sama sekali; tes interop M0 tetap lolos.
      Catatan penting: (1) peran payload TLS natural — pendengar =
      server TLS, penghubung = klien TLS (kebalikan dari kanal utama),
      CN peer diperiksa kedua arah; (2) `wl-copy` melakukan fork dan
      anaknya menahan pipe stdout/stderr, jadi `Process.run` menunggunya
      selamanya — tes interop meluncurkannya terlepas dengan stdio ke
      /dev/null; (3) di `testWidgets`, I/O file async macet di zona
      fake-async — pembuatan identitas dan penanganan paket di tes
      widget harus dibungkus `tester.runAsync`; (4) dua tes interop
      tidak boleh jalan bersamaan (keduanya pairing ke daemon) —
      suite penuh dijalankan dengan `--concurrency=1`;
      (5) file_picker 13 mengubah API: `FilePicker.pickFile()` statis,
      `PlatformFile` tanpa `size` (pakai `length()` dan
      `readAsByteStream()`).
- [x] M3 Multimedia control (control the desktop players from the phone)
      and Run commands (list, run, streamed output).
      SELESAI 2026-11-22 14:34. Bukti: `flutter test --concurrency=1`
      53/53 lolos + 1 skip wajar (tes interop M3 tanpa fixture);
      `flutter analyze` bersih; `flutter build apk --debug` berhasil
      (mobile/build/app/outputs/flutter-apk/app-debug.apk, 181 MB).
      Bukti hidup dari log daemon (14:32:27): `pairing completed with
      0fb35563...`, `mpris.request ... {"requestPlayerList":true}`,
      `mpris Pause -> mpv`, `mpris Play -> mpv`, `setVolume: 50`,
      `SetPosition: 5000000`; tes mencatat daftar perintah daemon
      `[cmd1795325153461, m3-interop-echo]` dan output streaming
      `[m3-interop-hello, baris-kedua, selesai]` lalu finished sukses
      kode keluar 0. Daemon TIDAK diubah sama sekali; tes interop M0/M2
      tetap lolos.
      Catatan penting: (1) mpv 0.42 di laptop TIDAK mendaftarkan
      org.mpris.MediaPlayer2, jadi bukti MPRIS live memakai player
      palsu kecil via D-Bus (dbus-python, /tmp, sudah dihapus) yang
      berbicara antarmuka MPRIS persis seperti yang dibaca daemon
      (Identity/Metadata/PlaybackStatus/Volume/Position + sinyal
      PropertiesChanged); (2) perintah tes `m3-interop-echo` sempat
      ditambahkan ke commands.json lalu DIHAPUS dan daemon di-restart
      dua kali lewat compositor — commands.json kini kembali seperti
      semula (hanya Terminal/kitty), daemon active, port 1714 listen;
      (3) tarik sampul album (transferringAlbumArt + receiveBytes)
      sudah diimplementasikan tapi BELUM terbukti live karena player
      palsu tidak punya sampul — perlu player sungguhan ber-sampul
      saat ada kesempatan; (4) parseCommandList kini tahan JSON rusak
      (ditemukan tes: jsonDecode melempar); (5) tes interop M3 skip
      dengan jujur bila mpv tidak jalan atau perintah tes tidak ada,
      seperti pola skip M2 saat daemon mati.
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
- 2026-11-22 14:15 M2 selesai (lihat centang di atas). File baru:
  mobile/lib/src/protocol/payload.dart (batas 512000 karakter,
  sanitasi nama file, dedup `nama (n).ext`, model ReceivedFile),
  mobile/lib/src/ui/share_page.dart (pilih file lewat picker sistem,
  kirim dengan progres, daftar file diterima),
  mobile/lib/src/ui/clipboard_page.dart (tulis/tempel/kirim, papan
  klip terakhir diterima). Perubahan protokol: DeviceConnection
  .sendClipboard() (tolak isi di atas batas daemon),
  .sendFile() (listener payload + share.request + streaming TLS),
  .receiveFile() (unduh payload ke folder terima), remoteAddress
  dari kanal utama. AppState menangani paket masuk: clipboard
  (dengan echo guard) mengatur papan klip HP, share.request teks
  jadi clipboard dan url hanya dicatat, file diunduh ke
  HyprConnect/ di penyimpanan eksternal (fallback dokumen app).
  Ubin Kirim file dan Kirim papan klip kini membuka halaman
  sungguhan, bukan placeholder. Tes baru: test/share_test.dart
  (5: bentuk paket, sanitasi, dedup, batas clipboard, round-trip
  payload dua arah), test/clipboard_page_test.dart (2 widget),
  test/interop_m2_test.dart (1: empat arah melawan daemon).
  Dependensi baru: file_picker ^13.4.1 (pub.dev publik).
- 2026-11-22 14:34 M3 selesai (lihat centang di atas). File baru:
  mobile/lib/src/protocol/mpris.dart (model state + pembangun paket
  requestPlayerList/requestNowPlaying/action/setVolume/Seek/
  SetPosition/albumArt; aksi hanya 6 yang dikenal daemon),
  mobile/lib/src/protocol/runcommand.dart (parse commandList string
  JSON + event output started/output/finished + pembangun paket
  list/run/stop/setup), mobile/lib/src/ui/multimedia_page.dart
  (pilih player, kartu now-playing + sampul, slider posisi dan
  volume, tombol putar/jeda/sebelum/berikut/berhenti/mundur-maju
  10 detik), mobile/lib/src/ui/runcommand_page.dart (daftar
  perintah, jalankan, log output streaming, tombol hentikan,
  ubah daftar di desktop). DeviceConnection: metode kirim M3 +
  receiveBytes (payload ke memori untuk sampul album). AppState:
  state MPRIS per perangkat (daftar player, state, player terpilih,
  jalur sampul, minta sampul sekali per URL) + state runcommand
  (daftar perintah, canAddCommand, event output maks 500, id
  perintah berjalan). Ubin Kendali multimedia dan Jalankan Perintah
  kini membuka halaman sungguhan. Tes baru: test/mpris_test.dart
  (11), test/runcommand_test.dart (5), test/multimedia_page_test.dart
  (3 widget, kartu ter-render sungguhan via hook
  registerTestConnection), test/runcommand_page_test.dart (2 widget),
  test/interop_m3_test.dart (1 live). Daemon TIDAK diubah.
- Next step: M4 — Masukan jarak jauh: touchpad dan keyboard ke
  desktop (kdeconnect.mousepad.request, semantik sama seperti yang
  sudah diimplementasikan daemon untuk aplikasi bawaan).

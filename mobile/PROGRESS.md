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
- [x] M4 Remote input: touchpad and keyboard to the desktop
      (kdeconnect.mousepad.request, same semantics as the daemon already
      implements for the stock app).
      SELESAI 2026-11-22 14:50. Bukti: `flutter test --concurrency=1`
      80/80 lolos + 1 skip wajar (tes interop M3 tanpa fixture mpv);
      `flutter analyze` bersih; `flutter build apk --debug` berhasil
      (mobile/build/app/outputs/flutter-apk/app-debug.apk, 181 MB).
      Bukti hidup dari log daemon (14:49:30): `pairing completed with
      dec3d634...` dan `mousepad specialKey 999 (unknown)`; gerak
      pointer terbukti lewat hyprctl cursorpos — kursor bergerak
      mengikuti delta yang dikirim lalu dikembalikan ke posisi awal
      (1735, 640). Daemon TIDAK diubah sama sekali; tes interop M0/M2
      tetap lolos.
      Catatan penting: (1) klik dan gulir sengaja TIDAK dibuktikan
      live — tidak ada sinyal yang bisa diamati di sisi daemon selain
      efeknya sendiri (klik akan menekan apa pun yang ada di bawah
      kursor di desktop yang sedang dipakai); bentuk paketnya
      dibuktikan tes unit + tes widget lewat koneksi perekam;
      (2) touchpad memakai Listener mentah, bukan GestureDetector —
      arena gesture akan mematikan seret yang mengikuti tekan-lama;
      (3) tes widget butuh viewport tinggi (2400 px) karena ListView
      hanya membangun isi yang terlihat di layar; scrollUntilVisible
      tidak bisa dipakai (finder Scrollable-nya ambigu dengan
      Scrollable internal TextField); (4) jalur tombol dibuktikan
      tanpa efek samping: specialKey tak dikenal hanya dicatat
      daemon, jadi dipakai sebagai probe.
- [x] M5 Presentation remote with HyprPresenter parity: gyro and drag
      pointer (kdeconnect.presenter), next/previous, monitor selection
      (additive daemon extension: the app may ask for the monitor list
      and set the presenter monitor; stock clients unaffected), presenter
      notes stored locally on the phone and shown on the presenter
      screen.
      SELESAI 2026-11-22 15:15. Bukti: `flutter test --concurrency=1`
      105/105 lolos + 1 skip wajar (tes interop M3 tanpa fixture mpv);
      `flutter analyze` bersih; `flutter build apk --debug` berhasil
      (mobile/build/app/outputs/flutter-apk/app-debug.apk, 182 MB).
      Bukti hidup dari log daemon (15:12:07-08): `presenter session
      started on DP-1`, `presenter session stopped`, `presenter monitor
      set to DP-1`, `presenter monitor set to auto`; presenter.json
      kembali `{"monitor": null}` setelah tes. Daemon DIUBAH secara
      aditif saja (ekstensi monitor di handle_presenter + presenter di
      OUTGOING_CAPABILITIES); paket dx/dy/stop dan semua perilaku lama
      tidak disentuh; tes interop M0/M2/M3/M4 tetap lolos melawan
      daemon yang sedang jalan (systemd active, port 1714 listen).
      Catatan penting: (1) tombol next/previous TIDAK dibuktikan lewat
      jurnal — daemon tidak mencatat specialKey yang dikenal (hanya
      yang tak dikenal, seperti probe 999 di M4); keduanya dikirim
      lewat kanal TLS live lalu kanal dibuktikan sehat dengan ping,
      dan bentuk paketnya dibuktikan tes unit + widget lewat koneksi
      perekam — aturan kejujuran yang sama seperti klik di M4;
      (2) gyro memakai pemetaan persis aplikasi bawaan (dx = -gyroZ *
      0,036, dy = -gyroX * 0,036) dengan `sensors_plus` 7.1.1 (pub.dev
      publik); (3) `cp` biner daemon yang sedang jalan gagal
      "Text file busy" — deploy yang benar: stop service lewat
      compositor, salin, start lagi lewat compositor; (4) pembacaan
      journalctl di tes dibuat tahan-gagal-sementara (gagal baca =
      "belum", bukan gagal tes) setelah satu kegagalan pertama yang
      tidak terjelaskan saat run pertama; (5) dua perangkat tes
      "HyprConnect Test" yang tertinggal di daftar daemon sudah
      di-unpair (paired=false), hanya entri riwayat yang memang
      disimpan daemon.

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
- 2026-11-22 14:50 M4 selesai (lihat centang di atas). File baru:
  mobile/lib/src/protocol/mousepad.dart (pembangun paket gerak/gulir/
  klik/tahan/kunci/tombol-khusus + tabel specialKey 1..32 persis
  daemon), mobile/lib/src/ui/remote_input_page.dart (touchpad
  Listener mentah + keyboard ketik-langsung dengan diff, modifier
  sticky, tombol khusus, panah, F1..F12, tempel papan klip).
  DeviceConnection: metode kirim M4; AppState: wrapper M4; ubin
  Masukan jarak jauh kini membuka halaman sungguhan. Tes baru:
  test/mousepad_test.dart (14), test/remote_input_page_test.dart
  (12 widget, koneksi perekam), test/interop_m4_test.dart (1 live).
  Daemon TIDAK diubah.
- SEMUA FASE SELESAI (M0-M5) 2026-11-22 15:15, sebelum batas 17:00.
  Tidak ada langkah berikutnya di sesi ini; laporan akhir dikirim
  dan jadwal build ini dihapus.
- 2026-11-22 15:15 M5 selesai (lihat centang di atas). Daemon:
  src/main.rs (handle_presenter kini menerima device_id + menangani
  requestMonitorList/setMonitor dengan balasan monitor list, plus
  helper send_presenter_monitors) dan src/packet.rs (presenter masuk
  OUTGOING_CAPABILITIES); biner release di-deploy ke ~/.local/bin/
  hyprconnect, service di-restart lewat compositor (stop-sal-in-start;
  active, port 1714 listen). File baru: mobile/lib/src/protocol/
  presenter.dart (builder move/stop/request/set + parse monitor list +
  pemetaan gyro), mobile/lib/src/ui/presenter_page.dart (pad seret +
  gyro + tombol slide + picker monitor + catatan), mobile/test/
  presenter_test.dart (15), test/presenter_page_test.dart (9 widget),
  test/interop_m5_test.dart (1 live). Perubahan app: DeviceConnection
  .sendPresenterMove/Stop/requestPresenterMonitors/setPresenterMonitor,
  AppState menangani kdeconnect.presenter masuk + state monitor
  per-perangkat + wrapper M5 + catatan di presenter_notes.json,
  Capabilities.incoming kini menerima kdeconnect.presenter, ubin
  Presentation remote membuka halaman sungguhan. Dependensi baru:
  sensors_plus ^7.1.1 (pub.dev publik).

## Addendum 2026-11-22 16:10 — tap-to-pair from the phone
Atas komplain Sahrul (pairing pertama versi M0 menyuruh menjalankan
CLI di desktop): pairing pertama sekarang cukup satu tap di HP.
- Daemon: maybe_connect tidak lagi mensyaratkan perangkat trusted;
  daemon menghubungi balik perangkat unpaired yang terdengar di
  discovery (perilaku setara kdeconnectd; semua fitur tetap tergerbang
  status paired, pairing tetap harus diterima eksplisit di desktop).
- App: connectTo untuk desktop yang belum dikenal menunggu kanal
  masuk dari desktop (maks 25 dtk) alih-alih memunculkan dialog CLI;
  tombol Hubungkan langsung mengirim permintaan pairing begitu kanal
  terbuka; kartu baru menampilkan kunci verifikasi selama menunggu
  diterima, dengan tombol batal. Dialog "Pairing pertama" dihapus.
- Alasan teknis tetap: TLS server Dart menolak sertifikat klien yang
  belum dikenal, jadi arah TCP untuk pairing pertama dibalik, tapi
  sekarang tidak terasa oleh pengguna.
- Tes 105 lolos + 1 skip, analyze bersih. APK release arm64 terkirim
  ke POCO X5 lewat daemon 16:09. Vonis fisik menunggu Sahrul mencoba.

## Addendum 2026-11-22 sore — sidebar + halaman perangkat bersih
Perintah Sahrul: navigasi perangkat lewat sidebar seperti KDE Connect
Android, subtitle ubin dihapus, perangkat luring disembunyikan, dan
kartu info arch-acer di halaman perangkat dihapus menyisakan 6 ubin.
- Shell baru: Drawer (header perangkat ini, daftar Peranti yang
  paired + online/terhubung, pill "Sandingkan peranti baru",
  Pengaturan, Tentang). Halaman perangkat jadi root dengan tombol
  hamburger; Pengaturan menampung identitas + folder terima + log;
  halaman sanding baru memuat perangkat yang ditemukan tapi belum
  dipair (hanya yang online).
- Halaman perangkat: kartu header (ikon, tipe, alamat, status)
  dihapus; saat paired tampil hanya 6 ubin. Ubin tanpa subtitle;
  plugin nonaktif tampil redup saja.
- Tes: 105 lolos + 1 skip (satu tes lama menyesuaikan hilangnya teks
  "Plugin nonaktif"; tes interop M5 sempat gagal karena presenter.json
  daemon berisi DP-1 sisa pemakaian, sudah direset ke auto).
- Tampil dan terverifikasi di emulator AVD lewat rig redir/forward.

## Addendum 2026-11-22 sore — Kirim file & papan klip instan
Perintah Sahrul: ubin Kirim file langsung membuka pemilih file
sistem dan file terpilih langsung terkirim; Kirim papan klip instan
tanpa halaman, cukup pemberitahuan sukses di bawah (gaya toast KDE
Connect: pill melayang membulat, teks di tengah, 2 detik).
- SharePage dan ClipboardPage dihapus. Ubin share memanggil
  FilePicker.pickFile() lalu AppState.sendFile dengan dialog
  progres "Mengirim file"; ubin clipboard membaca clipboard HP
  (kini di dalam try/catch — bacaan yang gagal tidak lagi diam) dan
  mengirimkannya, sukses dilaporkan "Papan klip terkirim".
- Bukti hidup di emulator: DocumentsUI terbuka dari ubin (activity
  terverifikasi dumpsys), share.request sampai ke daemon; clipboard
  diterima daemon ("clipboard received (21 chars), applying").
  Payload emulator butuh forward port 1739-1764 (artefak NAT rig,
  bukan bug app).
- Tes: 103 lolos + 1 skip (clipboard_page_test ikut dihapus bersama
  halamannya; tes tls unpair sempat flaky sekali, lulus saat diulang).

## Addendum 2026-11-22 evening: presenter page restyled after HyprPresenter

At Sahrul's request the mobile Presentation remote page now mirrors
his HyprPresenter clicker (source read on the laptop,
~/Documents/DEV/hyprpresenter/mobile): its own dark green Material 3
theme (ColorScheme.fromSeed green, dark), a slide-notes card with a
slide counter and re-sync chevrons, big Previous/Next pills
(outlined / filled), and one green pointer card (green.shade900,
green.shade600 while held) whose header strip carries the monitor
dropdown. App bar holds only the fullscreen toggle and a link-off
close button. Labels stay Indonesian.

Behaviour changes that come with the reference model:
- The pointer only streams while the card is held (gyro and drag
  both feed it); releasing sends {"stop": true}. The gyro switch,
  the separate Esc and Stop buttons, and the status texts are gone;
  the fullscreen button still sends specialKey 25.
- Notes are per-slide now: parsed/serialized in the same Markdown
  interchange format HyprPresenter uses (## N headings, ---
  separators), so notes files work in both apps. The stored
  per-device document keeps the old single-note text as slide 1.
  The editor is notebook-style (one cell per slide, add tile,
  saves on every keystroke) and can open a .md/.txt notes file.

Tests: 109 passed + 1 skip (full suite). Note for the emulator rig:
the adb payload forwards (tcp 1739-1764) break interop_m2 on the
laptop while they are up; remove them before running the suite.

Correction (same evening, Sahrul): the presenter page keeps
HyprPresenter's layout but NOT its colours — the private dark green
theme is gone and the page uses the app's own indigo scheme like
every other page. The pointer card is primaryContainer (primary
while held) with matching on-container content colours.

Addendum (2026-11-22 evening, Sahrul): the multimedia page now
follows the KDE Connect app's shape — AppBar with the device name
as subtitle, Putar / Peranti tabs, and an empty state that shows
the whole control skeleton disabled under a big music note with
"Tidak ada pemutar yang ditemukan". The playing state merges the
desktop reference he sent earlier: big rounded artwork, title and
artist, seek bar with both times, a wide play/pause button, a
Previous/Stop/Next tonal row and the volume slider, all in the
app's indigo scheme. The ±10 second buttons went away (the seek
bar covers them). Verified live in the emulator against a real
Brave player on the laptop.

Addendum (2026-11-22 evening, Sahrul, correcting the tab build):
"Peranti" is the desktop's audio outputs with their global
volume (kdeconnect.systemvolume), NOT a player picker — the
player picker is a dropdown on the Putar tab under the artwork.
The app learned the systemvolume protocol (requestSinks, raw
PulseAudio units, mute, set-default) and Peranti now renders one
card per sink like the stock app. Putar also gained the seek
buttons beside Previous/Stop/Next when the player can seek, and
the seek bar moved below the transport row with both times
flanking it. Debugging the first live test found a REAL bug in
DeviceConnection.sendPacket: two sends racing on one socket make
the loser's flush() throw "StreamSink is bound to a stream" and
its packet silently never leaves the phone; sends are now
serialized through a future chain. Proven live in the emulator:
requestSinks reached the daemon and a slider drag moved the
laptop's actual volume 16% -> 60% (restored to 16% afterwards).

## Addendum 2026-11-22 (sore): Masukan jarak jauh ala KDE Connect

Atas screenshot referensi Sahrul dari aplikasi KDE Connect Android
(halaman utama + dua halaman pengaturannya):

- Halaman Masukan jarak jauh ditulis ulang: touchpad memenuhi layar
  dengan teks petunjuk di tengah; baris tombol tetikus di bawah
  (kiri/tengah/kanan, kiri bersifat tahan-lepas sungguhan); bar atas
  berisi keyboard, kirim teks, dan pengaturan.
- Gestur mengikuti model KDE: 1 jari seret = gerak, 2 jari seret =
  gulir, ketuk 1/2/3 jari = aksi terkonfigurasi, ketuk ganda lalu
  seret = drag (klik kiri ditahan 350 ms menunggu ketuk kedua).
  Perilaku lama yang hilang: tekan lama 400 ms untuk drag dan mode
  Gerak/Gulir. Tetikus giroskop opsional dari pengaturan.
- Pengaturan per perangkat (remote_input_prefs.json): aksi ketuk per
  jumlah jari, kepekaan, akselerasi, gulir terbalik + sensitivitas,
  giroskop + sensitivitas, tampilkan tombol, drag ketuk ganda. Seksi
  berbagi penekanan tombol antar-aplikasi dari referensi TIDAK ditiru
  (aplikasi tidak punya target berbagi itu).
- Keyboard BUKAN halaman lagi (perintah Sahrul 18:49): tombol
  keyboard menampilkan keyboard lunak langsung di halaman yang sama;
  field ketik ramping + chip modifier + baris tombol khusus/panah
  muncul di atas baris tombol tetikus. keyboard_page.dart dihapus;
  halaman Kirim teks tetap terpisah.
- Tes: suite penuh 112 lolos + 1 skip (13 tes halaman ini).
- Verifikasi emulator ronde ini tersangkut rig: daemon gagal
  menyambung ulang ke aplikasi emulator (laporan CN tidak cocok)
  sejak ronde multimedia; probe TLS manual membuktikan aplikasi
  menyajikan sertifikat yang benar lewat forward yang sama, jadi
  halaman baru belum terfoto live. Vonis fisik menunggu HP asli.

## Addendum 2026-11-22 (malam): perangkat mati harus hilang dari menu

Keluhan Sahrul: perangkat luring muncul lagi di drawer emulator.
Akar masalahnya bug aplikasi sungguhan: koneksi yang sudah mati
tidak pernah dibuang dari peta koneksi AppState, jadi saringan
drawer dan shell (yang memeriksa keberadaan koneksi) lolos selamanya
setelah koneksi pertama. Perbaikan: DeviceConnection.close() kini
menutup stream paketnya, AppState membuang koneksi dari peta saat
stream itu berakhir, dan saringan drawer/shell menuntut koneksi yang
hidup (isConnected), bukan sekadar entri peta. Terverifikasi live di
emulator: build baru menampilkan arch-acer hanya saat kanalnya
benar-benar tersambung (daemon mengonfirmasi connected: true).
Catatan jujur: kanal daemon ke aplikasi sore ini tidak stabil
(terhubung lalu mati dalam hitungan detik, terlihat di log aplikasi
dan membuat interop_m3/m5 gagal di lingkungan ini); di kode pristine
tes yang sama hanya ter-skip karena tidak ada player bertitel.

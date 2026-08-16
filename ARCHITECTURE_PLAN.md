# Notch Agent — Swift + TypeScript BSC Testnet MVP

## Ringkasan

Bangun aplikasi macOS native yang hidup di Notch/menu bar dengan SwiftUI/AppKit. Semua integrasi AI, BNB Agent, ERC-8004, x402, dan transaksi BSC dijalankan oleh runtime TypeScript lokal berbasis Node.js serta SDK resmi [`@bnbagent/sdk`](https://github.com/bnb-chain/bnbagent-sdk).

MVP memakai BSC Testnet dan dua wallet terpisah:

- User wallet: seed phrase diimpor lokal; transfer, swap, dan fund wallet agent selalu dimulai serta dikonfirmasi user.
- Agent wallet: dibuat baru saat onboarding; agent dapat membayar layanan x402 otomatis tanpa konfirmasi transaksi dari user, hanya dari saldonya sendiri.

## Arsitektur

- **Native shell:** SwiftUI/AppKit untuk Notch panel, menu bar, onboarding, Touch ID/password unlock, notifikasi macOS, QR receive, dan pengaturan.
- **Agent runtime:** proses Node.js lokal TypeScript memakai `@bnbagent/sdk` untuk ERC-8004 identity/discovery, x402 payments, RPC BSC Testnet, serta tool loop untuk endpoint OpenAI-compatible.
- **Data lokal:** SQLite menyimpan konfigurasi non-rahasia, activity log, transaksi, chat history, dan state agent.
- **Key custody:** user-wallet dan agent-wallet memakai keystore terpisah. Password keystore, API key AI, serta konfigurasi sensitif disimpan di macOS Keychain; seed phrase tidak disimpan, tidak masuk log, dan tidak pernah diteruskan ke model AI.
- **Trust boundary:** runtime agent hanya dapat memakai agent-wallet. User-wallet tidak mempunyai tool otomatis dan hanya dapat menandatangani tindakan manual melalui UI Swift.

## BNB Chain Developer Kit capability layer

Semua resource dari [BNB Chain Developer Kit](https://docs.bnbchain.org/developer-kit/) tersedia melalui adapter yang dapat diaktifkan, dengan batas keamanan wallet yang sama. Tidak ada resource yang mendapat akses langsung ke seed phrase atau private key.

| Resource resmi | Peran dalam Notch Agent | Status |
| --- | --- | --- |
| BNB Agent SDK | ERC-8004 identity/discovery dan x402 client untuk agent-wallet. | MVP core |
| BNB Agent Studio | Scaffold, recipe, CLI diagnostics, dan security reference untuk mengembangkan agent seller terpisah. Tidak dibundel ke aplikasi karena Studio saat ini seller-only dan memakai runtime/deployment Python. | Developer tool / opt-in |
| Greenfield SDK | Menyimpan metadata identity, attachment/deliverable non-rahasia, dan data agent yang ingin dibagikan secara decentralized. Seed phrase, private key, API key, chat pribadi, dan log lokal tidak boleh diunggah. | Opt-in |
| MCP & Ask AI | Ask AI menjadi sumber read-only untuk chat BNB ecosystem; `bnbchain-mcp` hanya diekspos dengan tool baca. Semua tool tulis tetap melalui transaction service app agar pemisahan user-wallet/agent-wallet tidak bocor. | MVP read-only; write diblokir |
| MPP SDK | Maker mode opsional untuk membuat endpoint HTTP berbayar `402 Payment Required`, sehingga Notch Agent juga dapat menawarkan service kepada agent lain. Gunakan replay store durable sebelum endpoint dipublikasikan. | Fase commerce berikutnya |
| Scaled UI Amount (ERC-8056) | Deteksi token kompatibel dan tampilkan `balanceOfUI`, `toUIAmount`, serta `fromUIAmount` agar saldo, harga, dan input transfer/swap tidak salah saat multiplier berubah. | MVP wallet capability |
| Privacy at Scale | Provider/roadmap untuk fitur privacy BSC (ZKP/FHE dan privacy pool) setelah ada API/SDK yang stabil. Tidak ada custody atau privacy claim yang diaktifkan otomatis pada MVP. | Riset / future opt-in |

Setiap adapter memakai feature flag, version pin, health check, dan audit event. Kegagalan adapter hanya menonaktifkan capability terkait; tidak boleh mengganggu wallet, chat, atau background agent lain.

## Fitur & flow MVP

- Onboarding: unlock app → import user wallet → tampilkan receive address/QR → buat agent wallet baru → fund agent melalui transfer manual dari user wallet → optional register ERC-8004.
- Wallet: lihat BNB/ERC-20 balance dan history, receive, transfer, serta swap BSC Testnet melalui adapter PancakeSwap. Semua aksi wallet user melalui quote/simulasi lalu persetujuan user.
- Assistant: chat umum, chat ekosistem BNB, serta context read-only untuk saldo, history, dan status agent.
- Agent commerce: agent dapat menemukan layanan ERC-8004 atau memakai URL layanan yang dipilih user. Jika layanan memberi x402 challenge valid di BSC Testnet dan saldo agent cukup, agent membayar otomatis dan mengirimkan notifikasi beserta receipt.
- BNB knowledge: assistant menjawab pertanyaan ekosistem BNB dengan Ask AI MCP sebagai sumber dokumentasi read-only dan menyertakan link sumber pada jawaban yang berbasis dokumen.
- Token display: wallet mendeteksi ERC-8056 sebelum memformat saldo atau menerima input token yang kompatibel; app memakai nilai UI untuk tampilan dan mengonversinya kembali ke raw amount sebelum broadcast.
- Agent maker mode: setelah MVP buyer stabil, user dapat mengaktifkan endpoint MPP lokal/publik untuk menjual tool agent dan menerima payment receipt yang terlindungi replay store. Greenfield dapat dipakai untuk metadata/deliverable publiknya.
- Agent berjalan saat menu-bar app aktif dan sesi app unlocked. Saat layar Mac terkunci atau kill switch diaktifkan, agent berhenti dan tidak dapat membuat signature baru.
- Notch panel menampilkan saldo agent, agent active/paused, transaksi terakhir, tombol pause, dan akses cepat ke chat/wallet.

## Test plan

- Unit: import wallet, pemisahan keystore, Keychain access, x402 parsing, nonce/idempotency, secret redaction, pause/lock state.
- Integration BSC Testnet: transfer dan fund agent, receive QR, swap user manual, ERC-8004 registration/discovery, dan x402 automatic payment.
- E2E macOS: onboarding, chat, user-wallet confirmation, agent payment tanpa confirmation, insufficient balance, provider/RPC error, kill switch, dan screen-lock stop.
- Developer Kit: MCP read-only tidak dapat mengakses write tool atau key; ERC-8056 conversion benar untuk balance/history/input; Greenfield menolak data rahasia; serta MPP menolak replayed atau malformed payment credential.
- Gunakan mock x402 provider untuk test deterministik, lalu verifikasi satu pembayaran terhadap layanan BSC Testnet kompatibel.

## Asumsi

- Target awal adalah aplikasi personal macOS di BSC Testnet, dijalankan manual—bukan launch-at-login.
- Agent boleh memakai seluruh saldo agent-wallet tanpa limit nominal atau approval per transaksi; user hanya mendanai jumlah yang siap digunakan agent.
- ERC-8183, BSC Mainnet, multi-agent, hardware wallet, dan agent control atas macOS bukan bagian MVP.
- Agent Studio dan MPP maker mode tidak dibundel dalam MVP buyer. Privacy at Scale merupakan capability roadmap karena dokumentasinya menjelaskan solusi/arah infrastruktur, bukan SDK app yang siap diintegrasikan.
- Rust tidak digunakan pada MVP. Jika aplikasi masuk mainnet atau mengelola dana lebih besar, signer agent dapat dipindahkan ke native/Rust security core tanpa mengubah UI atau protokol BNB.

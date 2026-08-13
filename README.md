# Grandivo Automation Workflows (n8n)

Repositori ini berisi workflow n8n dan konfigurasi Docker Swarm untuk otomasi operasional Grandivo.

## Isi repositori

- `stack-postgres.yml`: stack PostgreSQL untuk Portainer/Docker Swarm.
- `products.sql`: skema database katalog produk Grandivo.
- `olsera_to_postgres.json`: workflow sinkronisasi produk Olsera ke PostgreSQL.
- `olsera_daily_revenue.sql`: tabel, view, dan fungsi snapshot Sales details/omzet harian.
- `olsera_daily_revenue_to_postgres.json`: workflow Sales details dan omzet harian Olsera.
- `n8n-olsera-env-snippet.yml`: potongan environment untuk autentikasi Olsera pada stack n8n.
- `instagram.json`: workflow validasi consent pelanggan dan publikasi Instagram.
- `grok_daily_thankyou_video.json`: workflow video terima kasih harian via Grok Imagine.
- `.env.example`: contoh variabel non-rahasia untuk stack PostgreSQL.

## 1. Menyiapkan PostgreSQL di Portainer

Stack memakai volume persisten `grandivo_postgres_data`, overlay network eksternal
`grandivo_backend`, Docker secret `grandivo_postgres_password`, healthcheck
`pg_isready`, dan tidak membuka port PostgreSQL ke internet.

### Buat overlay network

Di Portainer, buka **Networks** lalu buat:

```text
Name: grandivo_backend
Driver: overlay
Enable manual container attachment: aktif
```

Alternatif dari manager node:

```bash
docker network create --driver overlay --attachable grandivo_backend
```

### Buat password sebagai Docker secret

Di Portainer, buka **Secrets** lalu buat:

```text
Name: grandivo_postgres_password
Value: password PostgreSQL yang kuat
```

Jangan menyimpan password di repository.

### Deploy stack PostgreSQL

Di Portainer:

1. Buka **Stacks** → **Add stack** → **Repository**.
2. Masukkan repository ini dan branch `main`.
3. Isi **Compose path** dengan `stack-postgres.yml`.
4. Deploy stack.

Nilai default:

```text
POSTGRES_DB=grandivo
POSTGRES_USER=grandivo_sync
POSTGRES_IMAGE=postgres:16-alpine
ADMINER_IMAGE=adminer:5.5.0-standalone
ADMINER_PORT=8080
```

`products.sql` hanya otomatis dijalankan ketika volume PostgreSQL masih kosong.
Perubahan skema berikutnya harus dijalankan sebagai migration atau dieksekusi manual.

Pada Swarm multi-node, pin PostgreSQL ke node penyimpanan atau gunakan shared storage.
Local named volume tidak otomatis berpindah antar-node.

### Hubungkan n8n ke network PostgreSQL

Tambahkan external network pada stack n8n:

```yaml
services:
  n8n:
    networks:
      - grandivo_backend

networks:
  grandivo_backend:
    external: true
```

Credential PostgreSQL di n8n:

```text
Host: grandivo-db_postgres
Port: 5432
Database: grandivo
User: grandivo_sync
Password: nilai secret grandivo_postgres_password
SSL: disable
```

Gunakan nama service yang tampil di menu **Services** Portainer bila berbeda.

### Membuka PostgreSQL melalui Adminer

Stack juga menjalankan Adminer pada port `8080`. Setelah stack selesai di-update atau
di-redeploy, buka:

```text
http://IP_SERVER:8080
```

Login dengan:

```text
System   : PostgreSQL
Server   : postgres
Username : grandivo_sync
Password : nilai secret grandivo_postgres_password
Database : grandivo
```

Jika `postgres` tidak terdeteksi, gunakan nama lengkap service PostgreSQL yang terlihat
di **Services** Portainer, misalnya `grandivo-db_postgres`.

Port yang dipublikasikan oleh Docker Swarm dapat diterima oleh setiap node melalui
routing mesh. Batasi TCP `8080` pada firewall/provider firewall hanya ke IP publik Anda,
atau letakkan Adminer di belakang reverse proxy HTTPS dengan autentikasi tambahan.
Jangan membuka port PostgreSQL `5432` ke internet. Nilai port Adminer dapat diganti
melalui environment `ADMINER_PORT`.

## 2. Menyiapkan autentikasi Olsera

Workflow tidak lagi memakai access token statis. Setiap eksekusi akan:

1. menukar `app_id` dan `secret_key` menjadi access token;
2. memvalidasi access token;
3. memakai token tersebut sebagai `Authorization: Bearer <access_token>`.

Tambahkan environment berikut pada service n8n. Potongan yang sama tersedia di
`n8n-olsera-env-snippet.yml`.

```yaml
services:
  n8n:
    environment:
      OLSERA_APP_ID: ${OLSERA_APP_ID}
      OLSERA_SECRET_KEY: ${OLSERA_SECRET_KEY}
      XAI_API_KEY: ${XAI_API_KEY}
      N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"
```

Di bagian **Environment variables** stack Portainer, isi:

```text
OLSERA_APP_ID=<app_id dari Olsera Console>
OLSERA_SECRET_KEY=<secret_key dari Olsera Console>
XAI_API_KEY=<API key xAI untuk Grok>
```

Jangan menaruh nilainya di GitHub. Update/redeploy stack n8n setelah variabel ditambahkan.

`N8N_BLOCK_ENV_ACCESS_IN_NODE=false` diperlukan karena workflow membaca
`$env.OLSERA_APP_ID` dan `$env.OLSERA_SECRET_KEY` pada HTTP Request node.

## 3. Import dan uji workflow Olsera

1. Download atau salin `olsera_to_postgres.json`.
2. Import ke n8n.
3. Buka node **Upsert Produk ke PostgreSQL** dan pilih credential PostgreSQL Grandivo.
4. Tidak perlu membuat credential Header Auth Olsera.
5. Jangan aktifkan jadwal dahulu.
6. Jalankan **Jalankan Manual untuk Pengujian**.

Alur workflow:

```text
Manual/Schedule
→ Ambil Access Token Olsera
→ Validasi Access Token Olsera
→ Ambil Data Produk Olsera
→ Validasi & Map Produk
→ Upsert Produk ke PostgreSQL
→ Ringkasan Hasil Sync
```

Endpoint yang digunakan:

```text
POST https://api-open.olsera.co.id/api/open-api/v1/id/token
GET  https://api-open.olsera.co.id/api/open-api/v1/en/product
```

Token request memakai multipart form-data:

```text
app_id
secret_key
grant_type=secret_key
```

Product List memakai:

```text
Authorization: Bearer <access_token>
per_page=100
page=1
```

Periksa hasil tabel:

```sql
SELECT
    olsera_id,
    name,
    sku,
    price,
    stock,
    is_active,
    synced_at
FROM products
ORDER BY updated_at DESC
LIMIT 20;
```

Jalankan workflow dua kali dan pastikan jumlah baris tidak berlipat. Setelah hasil benar,
aktifkan workflow. Timezone sudah `Asia/Jakarta` dan cron berjalan pukul 00:00 WIB.

### Catatan pagination

Workflow saat ini mengambil `page=1` dengan `per_page=100`. Setelah respons nyata berhasil,
periksa metadata pagination Olsera. Bila katalog lebih dari 100 produk, workflow harus
ditambah loop pagination sebelum digunakan sebagai sinkronisasi penuh.

Workflow sengaja gagal bila:

- access token tidak ditemukan;
- format respons produk tidak dikenali;
- jumlah produk nol;
- produk tidak memiliki ID atau nama;
- PostgreSQL tidak mengembalikan hasil upsert.

Query PostgreSQL menggunakan parameter `$1` sampai `$14`.

## 4. Sales details dan omzet harian Olsera

Workflow baru memakai endpoint laporan penjualan resmi:

```text
GET https://api-open.olsera.co.id/api/open-api/v1/en/report/salesdetails
```

Alurnya:

```text
Manual/Schedule 00:15 WIB
→ ambil token
→ buat tiga tanggal bisnis terakhir
→ tarik setiap halaman Sales details per tanggal
→ validasi respons, pagination, field nominal, dan kunci baris
→ ganti snapshot tanggal secara atomik di PostgreSQL
→ hitung omzet exact-decimal di PostgreSQL
```

Tiga hari terakhir ditarik ulang agar perubahan terlambat dapat dikoreksi. Satu
tanggal hanya diganti jika respons sukses dan halaman terakhir dapat dibuktikan dari
`meta.current_page/last_page`, `links.next`/`next_page_url`, `meta.total` yang cocok,
atau halaman akhir yang lebih pendek dari `per_page`. Pagination HTTP memakai query
`page={{ $pageCount + 1 }}` dengan tipe `qs`, lalu berhenti kecuali ada sinyal
eksplisit halaman berikutnya (`current < last`, `links.next`, `next_page_url`, atau
`total` yang belum tercapai). Tanpa tipe `qs`, n8n tidak mengubah query string dan
mengulang halaman 1 sampai proteksi respons identik. Setelah konfigurasi produksi
lengkap, respons kosong yang tervalidasi menjadi omzet `0`; respons error,
wrapper tidak dikenal, atau pagination meragukan tidak menulis DB.

### Siapkan database

Pada volume PostgreSQL baru, `stack-postgres.yml` memasang schema otomatis. Pada volume
lama yang belum memiliki tabel Olsera ini, jalankan:

```bash
psql -U grandivo_sync -d grandivo -f olsera_daily_revenue.sql
```

`CREATE TABLE IF NOT EXISTS` bukan alat migrasi schema yang sudah berbeda. Jika nama
tabel/fungsi tersebut sudah pernah dibuat dari versi eksperimen, backup lalu buat
migration `ALTER` yang ditinjau; jangan menganggap menjalankan ulang file akan mengubah
constraint atau primary key lama.

### Uji manual dan kunci definisi omzet

1. Import `olsera_daily_revenue_to_postgres.json` ke n8n.
2. Pilih ulang credential pada **Simpan Snapshot Harian ke PostgreSQL**.
3. Jangan aktifkan jadwal.
4. Biarkan konfigurasi definisi omzet kosong dan jalankan manual sekali. Node
   **Validasi & Normalisasi Sales Details** sengaja berhenti sebelum DB; inspeksi INPUT
   node itu untuk melihat schema respons nyata.
5. Pada **Tanggal Bisnis WIB & Konfigurasi**, isi semua nilai berikut berdasarkan
   respons nyata dan rekonsiliasi laporan Olsera:

```text
REVENUE_FIELD       path nominal yang dijumlahkan per report row
RECORD_KEY_FIELDS   satu/lebih path yang unik dan stabil per report row
ROW_GRAIN           arti satu row, mis. order atau order-line
WUNPAID             "0" atau "1" setelah uji A/B
AMOUNT_BASIS        definisi gross/net, diskon, pajak, retur
SOURCE_SCOPE        label tetap untuk akun/outlet/token ini
CALCULATION_VERSION versi definisi omzet, mis. v1
```

Dokumentasi Olsera belum menerbitkan schema respons, grain baris, timezone sumber,
field nominal, nilai default/makna pasti `wunpaid`, maupun apakah retur sudah
dikurangkan. Kandidat field dalam pesan error hanya bantuan diagnostik dan tidak pernah
dipakai otomatis. Uji `WUNPAID="0"` dan `"1"` pada tanggal yang sama, lalu cocokkan
pesanan belum dibayar, pembatalan, diskon, pajak, dan retur dengan laporan Olsera.

Setelah konfigurasi lengkap, jalankan ulang dua kali. Hasil tidak boleh berlipat dan
harus cocok dengan laporan Olsera sebelum workflow diaktifkan. Untuk backfill, isi
`MANUAL_BUSINESS_DATE` dengan tanggal kalender `YYYY-MM-DD`, lalu kosongkan kembali.

### Verifikasi hasil

```sql
SELECT *
FROM public.v_olsera_daily_revenue
ORDER BY source_scope, business_date DESC
LIMIT 30;

SELECT
    source_scope,
    business_date,
    record_key,
    order_no,
    revenue_amount,
    revenue_field,
    status,
    payment_status
FROM public.olsera_sales_detail_rows
ORDER BY source_scope, business_date DESC, record_key
LIMIT 100;

SELECT
    source_scope,
    business_date,
    SUM(revenue_amount) AS detail_sum
FROM public.olsera_sales_detail_rows
GROUP BY source_scope, business_date
ORDER BY source_scope, business_date DESC;
```

Workflow tidak menyimpan data eksekusi sukses/error di n8n untuk mengurangi retensi
token dan payload pelanggan. Raw report row tetap disimpan di PostgreSQL untuk audit;
gunakan user DB non-superuser dengan hak minimum dan tetapkan kebijakan retensi/akses.

Dokumentasi resmi: [Sales details](https://docs-api-open.olsera.co.id/documentation/sales-details)
dan [Token](https://docs-api-open.olsera.co.id/documentation/token).

## 5. Workflow Instagram

Sebelum mengaktifkan `instagram.json`:

1. Buat Google Sheet dengan kolom `Nama`, `Sosmed`, `Nomor Telepon`, `Consent`, dan `Consent At`.
2. Ganti `REPLACE_WITH_GOOGLE_SHEET_ID`.
3. Pilih credential Google Sheets dan HTTP Bearer Auth Instagram.
4. Pastikan URL gambar dapat diakses publik.
5. Uji menggunakan akun Instagram pengujian.

Workflow masih memublikasikan otomatis setelah data dan consent lolos validasi. Tambahkan
approval step bila tim Grandivo perlu memeriksa caption atau gambar terlebih dahulu.

## 6. Video terima kasih harian Grok

Workflow `grok_daily_thankyou_video.json` membuat satu video vertikal per hari:

```text
Terima kasih kak {X} yang telah membeli {Y} di Grandivo, semoga bermanfaat.
```

`X` adalah nama depan pembeli, `Y` adalah nama produk. Workflow **tidak** memublikasikan
ke Instagram. Video berisi nama pelanggan, jadi publikasi tetap butuh consent terpisah
seperti di `instagram.json`.

### Environment

Selain kredensial Olsera, tambahkan `XAI_API_KEY` pada stack n8n lalu update/redeploy.
Workflow gagal di awal jika kunci itu kosong.

### Import dan uji

1. Import `grok_daily_thankyou_video.json`.
2. Jangan aktifkan jadwal.
3. Untuk uji tanpa menunggu penjualan nyata, buka **Tanggal Bisnis & Konfigurasi** lalu isi:

```text
MANUAL_CUSTOMER_NAME: 'Andi'
MANUAL_PRODUCT_NAME: 'Kabel Data USB-C'
```

4. Jalankan **Jalankan Manual untuk Pengujian**.
5. Setelah hasil benar, kosongkan kedua field manual dan aktifkan workflow.

Jadwal default: `0 8 * * *` (08:00 WIB). Timezone workflow `Asia/Jakarta`. Produksi
mengambil Sales details tanggal kemarin, memilih satu pembelian berbayar yang punya
nama pelanggan dan produk, lalu membuat satu video.

Alur:

```text
Manual/Schedule 08:00 WIB
→ tanggal bisnis & konfigurasi
→ token Olsera (dilewati jika mode manual)
→ Sales details kemarin
→ pilih satu pembelian featured
→ Grok menulis brief video
→ Grok Imagine generate video 8 detik 9:16 720p
→ poll status sampai done
→ ringkasan + URL video
```

Endpoint:

```text
POST https://api-open.olsera.co.id/api/open-api/v1/id/token
GET  https://api-open.olsera.co.id/api/open-api/v1/en/report/salesdetails
POST https://api.x.ai/v1/chat/completions
POST https://api.x.ai/v1/videos/generations
GET  https://api.x.ai/v1/videos/{request_id}
```

Parser Sales details defensif: beberapa kandidat field nama pelanggan/produk dicoba.
Baris batal, void, refund, atau unpaid dilewati. Nama tamu/kosong dilewati. Hanya nama
depan yang masuk naskah.

Jika tidak ada pembelian yang memenuhi syarat, eksekusi berstatus `SKIPPED` dan tidak
memanggil xAI. URL video xAI bersifat sementara; unduh segera jika perlu disimpan.

## Backup minimum

Contoh backup manual dari manager node:

```bash
docker exec -t "$(docker ps --filter name=_postgres --format '{{.ID}}' | head -n1)" \
  pg_dump -U grandivo_sync -d grandivo --format=custom > grandivo-$(date +%F).dump
```

Simpan backup di lokasi lain, bukan hanya pada node Docker yang sama.

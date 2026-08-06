# Grandivo Automation Workflows (n8n)

Repositori ini berisi workflow n8n dan konfigurasi Docker Swarm untuk otomasi operasional Grandivo.

## Isi repositori

- `stack-postgres.yml`: stack PostgreSQL untuk Portainer/Docker Swarm.
- `products.sql`: skema database katalog produk Grandivo.
- `olsera_to_postgres.json`: workflow sinkronisasi produk Olsera ke PostgreSQL.
- `n8n-olsera-env-snippet.yml`: potongan environment untuk autentikasi Olsera pada stack n8n.
- `instagram.json`: workflow validasi consent pelanggan dan publikasi Instagram.
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

## 2. Menyiapkan autentikasi Olsera

Workflow tidak lagi memakai access token statis. Setiap eksekusi akan:

1. menukar `app_id` dan `secret_key` menjadi access token;
2. memvalidasi access token;
3. memakai token tersebut pada request Product List tanpa awalan `Bearer`.

Tambahkan environment berikut pada service n8n. Potongan yang sama tersedia di
`n8n-olsera-env-snippet.yml`.

```yaml
services:
  n8n:
    environment:
      OLSERA_APP_ID: ${OLSERA_APP_ID}
      OLSERA_SECRET_KEY: ${OLSERA_SECRET_KEY}
      N8N_BLOCK_ENV_ACCESS_IN_NODE: "false"
```

Di bagian **Environment variables** stack Portainer, isi:

```text
OLSERA_APP_ID=<app_id dari Olsera Console>
OLSERA_SECRET_KEY=<secret_key dari Olsera Console>
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
Authorization: <access_token>
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

## 4. Workflow Instagram

Sebelum mengaktifkan `instagram.json`:

1. Buat Google Sheet dengan kolom `Nama`, `Sosmed`, `Nomor Telepon`, `Consent`, dan `Consent At`.
2. Ganti `REPLACE_WITH_GOOGLE_SHEET_ID`.
3. Pilih credential Google Sheets dan HTTP Bearer Auth Instagram.
4. Pastikan URL gambar dapat diakses publik.
5. Uji menggunakan akun Instagram pengujian.

Workflow masih memublikasikan otomatis setelah data dan consent lolos validasi. Tambahkan
approval step bila tim Grandivo perlu memeriksa caption atau gambar terlebih dahulu.

## Backup minimum

Contoh backup manual dari manager node:

```bash
docker exec -t "$(docker ps --filter name=_postgres --format '{{.ID}}' | head -n1)" \
  pg_dump -U grandivo_sync -d grandivo --format=custom > grandivo-$(date +%F).dump
```

Simpan backup di lokasi lain, bukan hanya pada node Docker yang sama.

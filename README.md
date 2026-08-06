# Grandivo Automation Workflows (n8n)

Repositori ini berisi workflow n8n dan konfigurasi Docker Swarm untuk otomasi operasional Grandivo.

## Isi repositori

- `stack-postgres.yml`: stack PostgreSQL untuk Portainer/Docker Swarm.
- `products.sql`: skema database katalog produk Grandivo.
- `olsera_to_postgres.json`: workflow sinkronisasi produk Olsera ke PostgreSQL.
- `instagram.json`: workflow validasi consent pelanggan dan publikasi Instagram.
- `.env.example`: contoh variabel non-rahasia untuk stack PostgreSQL.

## 1. Menyiapkan PostgreSQL di Portainer

Stack memakai:

- volume persisten `grandivo_postgres_data`;
- overlay network eksternal `grandivo_backend`;
- Docker secret eksternal `grandivo_postgres_password`;
- `products.sql` sebagai initialization script;
- healthcheck `pg_isready`;
- tanpa membuka port PostgreSQL ke internet.

### Buat overlay network

Di Portainer, buka **Networks** lalu buat network:

```text
Name: grandivo_backend
Driver: overlay
Attachable: aktif
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

Alternatif dari manager node:

```bash
printf '%s' 'GANTI_DENGAN_PASSWORD_KUAT' | docker secret create grandivo_postgres_password -
```

Jangan menyimpan password di repository atau environment variable stack.

### Deploy stack dari Git repository

Di Portainer:

1. Buka **Stacks** → **Add stack**.
2. Pilih **Repository**.
3. Masukkan repository ini dan branch yang akan digunakan.
4. Isi **Compose path** dengan `stack-postgres.yml`.
5. Tambahkan environment variables dari `.env.example` jika ingin mengganti nilai default.
6. Deploy stack.

Nilai default:

```text
POSTGRES_DB=grandivo
POSTGRES_USER=grandivo_sync
POSTGRES_IMAGE=postgres:16-alpine
```

`products.sql` hanya otomatis dijalankan ketika volume PostgreSQL masih kosong. Perubahan skema setelah database pernah dibuat harus dijalankan sebagai migration atau dieksekusi manual.

### Hubungkan stack n8n

Tambahkan external network berikut pada stack n8n:

```yaml
networks:
  grandivo_backend:
    external: true
```

Lalu hubungkan service n8n ke network tersebut:

```yaml
services:
  n8n:
    networks:
      - grandivo_backend
```

Credential PostgreSQL di n8n:

```text
Host: postgres
Port: 5432
Database: grandivo
User: grandivo_sync
Password: nilai secret grandivo_postgres_password
SSL: disable untuk koneksi internal overlay network
```

Jika nama stack mengubah DNS service, gunakan nama service yang terlihat pada menu **Services** Portainer, biasanya `<nama-stack>_postgres`.

## 2. Import dan uji workflow Olsera

1. Import `olsera_to_postgres.json` di n8n.
2. Pada node **Ambil Data Produk Olsera**, pilih credential HTTP Header Auth Olsera.
3. Pada node **Upsert Produk ke PostgreSQL**, pilih credential PostgreSQL Grandivo.
4. Jangan aktifkan jadwal dahulu.
5. Jalankan **Jalankan Manual untuk Pengujian**.
6. Periksa output API Olsera dan hasil tabel:

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

7. Jalankan workflow untuk kedua kalinya dan pastikan jumlah baris tidak berlipat.
8. Setelah hasil benar, aktifkan workflow. Timezone workflow sudah diset ke `Asia/Jakarta` dan cron berjalan setiap pukul 00:00 WIB.

### Catatan pagination Olsera

Dokumentasi publik endpoint Olsera tidak cukup jelas untuk memastikan format pagination. Sebelum produksi, periksa respons nyata akun Olsera Anda. Bila respons memiliki `current_page`, `total_pages`, `next_page`, atau URL halaman berikutnya, aktifkan pagination pada HTTP Request node. Jangan menganggap halaman pertama sebagai seluruh katalog.

Workflow sengaja menghentikan proses ketika:

- format respons tidak dikenali;
- produk berjumlah nol;
- produk tidak memiliki ID atau nama;
- PostgreSQL tidak mengembalikan hasil upsert.

Query PostgreSQL menggunakan parameter `$1` sampai `$14`, bukan interpolasi string.

## 3. Workflow Instagram

Sebelum mengaktifkan `instagram.json`:

1. Buat Google Sheet dengan kolom `Nama`, `Sosmed`, `Nomor Telepon`, `Consent`, dan `Consent At`.
2. Ganti `REPLACE_WITH_GOOGLE_SHEET_ID`.
3. Pilih credential Google Sheets dan HTTP Bearer Auth Instagram.
4. Pastikan URL gambar dapat diakses publik tanpa login.
5. Uji menggunakan akun Instagram pengujian terlebih dahulu.

Perubahan keamanan pada workflow:

- nomor telepon diperlakukan sebagai teks;
- nama, nomor telepon, username, dan consent divalidasi sebelum disimpan;
- timestamp consent ikut disimpan;
- credential ID, webhook ID, cached URL, dan instance ID tidak disimpan di repository;
- request API memiliki retry terbatas.

## Backup minimum

Sebelum menjadikan PostgreSQL sebagai sumber data produksi, siapkan backup terjadwal. Contoh backup manual dari manager node:

```bash
docker exec -t "$(docker ps --filter name=_postgres --format '{{.ID}}' | head -n1)" \
  pg_dump -U grandivo_sync -d grandivo --format=custom > grandivo-$(date +%F).dump
```

Simpan hasil backup di lokasi lain, bukan hanya pada node Docker yang sama.

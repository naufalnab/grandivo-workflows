# Grandivo Executive Sales & Product Dashboard

Dashboard read-only untuk memantau ringkasan omzet penjualan, rincian kanal/metode pembayaran (*Payment By Method*), dan katalog produk hasil sinkronisasi Olsera POS ke PostgreSQL.

Arsitektur:

```text
Browser
  → Traefik / easypanel network
  → Nginx dashboard + Basic Auth
  → PostgREST API (internal only)
  → PostgreSQL grandivo-db_postgres
```

PostgREST tidak dipublish langsung ke internet. Nginx meneruskan `/api/*` secara internal dan seluruh dashboard dilindungi Basic Auth.

## Fitur

- **Daily Sales Closing & Payment Breakdown** (Sesuai format resmi ringkasan penutupan harian Olsera):
  - Ringkasan omzet total, total transaksi, kanal pembayaran terbesar, dan rata-rata order (AOV);
  - Daftar visual per metode pembayaran (CASH, EDC, QRIS, Marketplace Shopee/Tokopedia, Kredivo/Paylater) dengan persentase & bar progress;
  - Baris Total - IDR dengan nominal terformat rapi;
  - Filter tanggal bisnis (Hari ini, kemarin, per tanggal, atau rentang waktu);
  - Tombol **Salin Closing Summary** format teks WhatsApp/Email siap kirim;
  - Tabel rincian seluruh transaksi dengan modal payload audit JSON Olsera.
- **Katalog Produk**:
  - Total produk, produk aktif, total unit stok, nilai modal inventaris;
  - Pencarian multi-field (nama, SKU, ID, kategori, brand);
  - Filter kategori, brand, status stok (stok rendah / stok habis);
  - Detail spesifikasi produk & payload Olsera asli;
  - Export data ke CSV.
- **Sistem & Desain**:
  - Dukungan Dark Mode / Light Mode otomatis;
  - API aman menggunakan role PostgreSQL read-only (`grandivo_viewer`).

## 1. Buat role PostgreSQL read-only

Buat password yang aman dan mudah dipakai di connection URI, misalnya dari terminal:

```bash
openssl rand -hex 24
```

Masuk ke console container PostgreSQL Grandivo dan buka psql:

```bash
psql -U grandivo_sync -d grandivo
```

Lalu jalankan SQL berikut (atau jalankan script `dashboard-readonly.sql`):

```sql
CREATE ROLE grandivo_viewer NOLOGIN;
CREATE ROLE grandivo_dashboard LOGIN PASSWORD 'PASSWORD_RANDOM_DARI_OPENSSL';

GRANT USAGE ON SCHEMA public TO grandivo_viewer;
GRANT SELECT ON TABLE public.products TO grandivo_viewer;
GRANT SELECT ON TABLE public.olsera_sales_detail_rows TO grandivo_viewer;
GRANT SELECT ON TABLE public.olsera_daily_revenue TO grandivo_viewer;
GRANT SELECT ON TABLE public.v_olsera_daily_revenue TO grandivo_viewer;
GRANT SELECT ON TABLE public.v_olsera_sales_by_payment_method TO grandivo_viewer;
GRANT grandivo_viewer TO grandivo_dashboard;

ALTER ROLE grandivo_dashboard SET statement_timeout = '10s';
ALTER ROLE grandivo_dashboard SET default_transaction_read_only = on;
```

Jika role sudah pernah dibuat, gunakan `dashboard-readonly.sql` dari root repository. Script tersebut idempotent untuk pembuatan role dan menerima password melalui variabel psql.

## 2. Buat Basic Auth secret

Buat hash untuk user dashboard. Contoh menggunakan container Apache agar password diminta secara interaktif:

```bash
docker run --rm -it httpd:2.4-alpine htpasswd -nB admin
```

Output akan berbentuk seperti:

```text
admin:$2y$05$...
```

Di Portainer buka **Secrets → Add secret**:

```text
Name: grandivo_dashboard_htpasswd
Value: seluruh baris admin:$2y$05$...
```

Jangan commit hash/password aktual ke repository.

## 3. DNS

Tambahkan A record:

```text
products.grandivo.cloud → 187.127.105.183
```

Nama host dapat diganti melalui environment `DASHBOARD_HOST`.

## 4. Deploy di Portainer

Karena stack memakai Docker Config dari file repository, deploy menggunakan **Stacks → Add stack → Repository**, bukan paste Web editor.

Gunakan repository ini dan compose path:

```text
stack-product-dashboard.yml
```

Environment variables:

```text
DASHBOARD_HOST=products.grandivo.cloud
PGRST_DB_URI=postgres://grandivo_dashboard:PASSWORD_RANDOM_DARI_OPENSSL@grandivo-db_postgres:5432/grandivo
```

Opsional:

```text
DASHBOARD_NGINX_IMAGE=nginx:1.29-alpine
POSTGREST_IMAGE=postgrest/postgrest:v14.3
TRAEFIK_ENTRYPOINT=https
TRAEFIK_CERTRESOLVER=letsencrypt
```

Stack membutuhkan external network yang sudah dipakai Grandivo:

```text
easypanel
grandivo_backend
```

Setelah deploy, service yang diharapkan:

```text
<stack>_dashboard   1/1
<stack>_api         1/1
```

Buka:

```text
https://products.grandivo.cloud
```

Browser akan meminta username/password Basic Auth yang dibuat pada langkah 2.

## 5. Troubleshooting

Jika dashboard muncul tetapi data gagal dimuat, periksa log service `api`. Error `permission denied for table products` berarti grant SELECT belum diterapkan ke `grandivo_viewer`.

Jika `api` tidak dapat terhubung ke database, pastikan host pada `PGRST_DB_URI` adalah nama service PostgreSQL Swarm yang aktif, saat ini biasanya:

```text
grandivo-db_postgres
```

Jika halaman menghasilkan Bad Gateway, pastikan service `dashboard` terhubung ke network `easypanel`, dan Traefik juga memakai network tersebut.

Dashboard membatasi PostgREST maksimal 2.000 baris per request. Frontend saat ini membaca maksimal 2.000 produk dan melakukan filter/pagination di browser. Jika katalog tumbuh melampaui angka tersebut, pindahkan search/filter/pagination ke query server-side.

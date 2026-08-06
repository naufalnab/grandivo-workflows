# Grandivo Automation Workflows (n8n)

Repositori ini berisi workflow n8n otomatisasi untuk operasional **Grandivo**.

---

## 📋 Daftar Workflow

### 1. Sinkronisasi Olsera POS ke PostgreSQL (`olsera_to_postgres.json`)
- **Fungsi**: Mengambil katalog produk, stok, dan harga dari Olsera POS secara otomatis dan menyimpannya ke database PostgreSQL untuk website toko online baru pengganti grandivo.com.
- **Jadwal**: Setiap hari pukul 00:00 WIB (12 Malam).
- **Teknologi**: n8n (Schedule Trigger, HTTP Request, Code Node, PostgreSQL Node).

#### 🗄️ Skema Tabel PostgreSQL (`products`)
```sql
CREATE TABLE IF NOT EXISTS products (
    id SERIAL PRIMARY KEY,
    olsera_id VARCHAR(100) UNIQUE NOT NULL,
    name VARCHAR(255) NOT NULL,
    sku VARCHAR(100),
    price NUMERIC(12, 2) DEFAULT 0.00,
    buy_price NUMERIC(12, 2) DEFAULT 0.00,
    stock INT DEFAULT 0,
    weight NUMERIC(8, 2) DEFAULT 0.00,
    description TEXT,
    category VARCHAR(100),
    brand VARCHAR(100),
    image_url TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_products_olsera_id ON products(olsera_id);
CREATE INDEX IF NOT EXISTS idx_products_sku ON products(sku);
```

---

### 2. Instagram Mention Automation (`instagram.json`)
- **Fungsi**: Automasi posting & sebutan (mention) Instagram pelanggan Grandivo.

---

## 🚀 Cara Import ke n8n
1. Buka n8n instance Anda.
2. Pilih menu **Workflows** -> **Import from File**.
3. Upload file JSON workflow yang diinginkan (`olsera_to_postgres.json` atau `instagram.json`).
4. Atur Credentials (API Key / Header Auth & Database PostgreSQL).
5. Simpan dan aktifkan workflow.

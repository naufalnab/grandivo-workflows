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

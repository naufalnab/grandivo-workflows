CREATE TABLE IF NOT EXISTS products (
    id BIGSERIAL PRIMARY KEY,
    olsera_id VARCHAR(100) UNIQUE NOT NULL,
    name VARCHAR(255) NOT NULL,
    sku VARCHAR(100),
    price NUMERIC(14, 2) NOT NULL DEFAULT 0.00,
    buy_price NUMERIC(14, 2) NOT NULL DEFAULT 0.00,
    stock INTEGER NOT NULL DEFAULT 0,
    weight NUMERIC(12, 3) NOT NULL DEFAULT 0.000,
    description TEXT,
    category VARCHAR(150),
    brand VARCHAR(150),
    image_url TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    source_updated_at TIMESTAMPTZ,
    raw_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    synced_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- These ALTER statements keep the script safe to rerun if the table was created
-- by an older version of this repository.
ALTER TABLE products
    ADD COLUMN IF NOT EXISTS source_updated_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS raw_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS synced_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_products_sku
    ON products (sku)
    WHERE sku IS NOT NULL AND sku <> '';

CREATE INDEX IF NOT EXISTS idx_products_active
    ON products (is_active);

CREATE INDEX IF NOT EXISTS idx_products_last_seen_at
    ON products (last_seen_at DESC);

COMMENT ON TABLE products IS 'Product catalog synchronized from Olsera POS.';
COMMENT ON COLUMN products.olsera_id IS 'Stable product identifier from Olsera.';
COMMENT ON COLUMN products.raw_payload IS 'Last raw Olsera payload retained for troubleshooting.';
COMMENT ON COLUMN products.last_seen_at IS 'Last successful sync in which the product was returned by Olsera.';

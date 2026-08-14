CREATE TABLE IF NOT EXISTS public.olsera_sales_detail_rows (
    id BIGSERIAL PRIMARY KEY,
    source_scope VARCHAR(128) NOT NULL,
    business_date DATE NOT NULL,
    record_key VARCHAR(320) NOT NULL,
    order_id TEXT,
    order_no TEXT,
    source_timestamp_raw TEXT,
    status TEXT,
    payment_status TEXT,
    payment_method TEXT,
    customer_id TEXT,
    store_id TEXT,
    revenue_amount NUMERIC NOT NULL,
    revenue_field TEXT NOT NULL,
    row_grain TEXT NOT NULL,
    calculation_version TEXT NOT NULL,
    raw_payload JSONB NOT NULL,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    synced_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT olsera_sales_detail_rows_scope_not_blank
        CHECK (BTRIM(source_scope) <> ''),
    CONSTRAINT olsera_sales_detail_rows_key_not_blank
        CHECK (BTRIM(record_key) <> ''),
    CONSTRAINT olsera_sales_detail_rows_key_size
        CHECK (OCTET_LENGTH(record_key) <= 1000),
    CONSTRAINT olsera_sales_detail_rows_raw_object
        CHECK (jsonb_typeof(raw_payload) = 'object'),
    UNIQUE (source_scope, business_date, record_key)
);

ALTER TABLE IF EXISTS public.olsera_sales_detail_rows
    ADD COLUMN IF NOT EXISTS payment_method TEXT;

CREATE INDEX IF NOT EXISTS idx_olsera_sales_detail_rows_scope_date
    ON public.olsera_sales_detail_rows (source_scope, business_date DESC);

CREATE TABLE IF NOT EXISTS public.olsera_daily_revenue (
    source_scope VARCHAR(128) NOT NULL,
    business_date DATE NOT NULL,
    omzet NUMERIC NOT NULL DEFAULT 0,
    report_row_count INTEGER NOT NULL DEFAULT 0,
    page_count INTEGER NOT NULL DEFAULT 0,
    revenue_field TEXT NOT NULL,
    record_key_fields JSONB NOT NULL,
    row_grain TEXT NOT NULL,
    wunpaid CHAR(1) NOT NULL,
    amount_basis TEXT NOT NULL,
    calculation_version TEXT NOT NULL,
    source_endpoint TEXT NOT NULL,
    source_fetched_at TIMESTAMPTZ NOT NULL,
    source_metadata JSONB NOT NULL DEFAULT '[]'::jsonb,
    synced_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (source_scope, business_date),
    CONSTRAINT olsera_daily_revenue_scope_not_blank
        CHECK (BTRIM(source_scope) <> ''),
    CONSTRAINT olsera_daily_revenue_report_rows_nonnegative
        CHECK (report_row_count >= 0),
    CONSTRAINT olsera_daily_revenue_page_count_positive
        CHECK (page_count > 0),
    CONSTRAINT olsera_daily_revenue_record_key_fields_array
        CHECK (jsonb_typeof(record_key_fields) = 'array'),
    CONSTRAINT olsera_daily_revenue_wunpaid_known
        CHECK (wunpaid IN ('0', '1')),
    CONSTRAINT olsera_daily_revenue_source_metadata_array
        CHECK (jsonb_typeof(source_metadata) = 'array')
);

COMMENT ON TABLE public.olsera_sales_detail_rows IS
    'Rows returned by the Olsera Sales details report. The API documentation does not guarantee that one row equals one order.';

COMMENT ON COLUMN public.olsera_sales_detail_rows.payment_status IS
    'Verbatim payment status returned by Olsera (e.g. is_paid/payment_status).';

COMMENT ON COLUMN public.olsera_sales_detail_rows.payment_method IS
    'Payment method or payment channel extracted from the Olsera sales detail row.';

COMMENT ON COLUMN public.olsera_sales_detail_rows.revenue_amount IS
    'Exact decimal read from the explicitly configured revenue_field; no locale or floating-point conversion is applied.';

COMMENT ON COLUMN public.olsera_sales_detail_rows.source_timestamp_raw IS
    'Source timestamp preserved verbatim because the Olsera report timezone is not documented.';

COMMENT ON COLUMN public.olsera_sales_detail_rows.raw_payload IS
    'Raw Olsera row for audit. It may contain personal data; apply least privilege and a retention policy.';

COMMENT ON TABLE public.olsera_daily_revenue IS
    'One exact, replaceable Sales details snapshot per source scope and business date.';

CREATE OR REPLACE FUNCTION public.replace_olsera_daily_sales(
    p_source_scope TEXT,
    p_business_date DATE,
    p_rows JSONB,
    p_report_row_count INTEGER,
    p_page_count INTEGER,
    p_revenue_field TEXT,
    p_record_key_fields JSONB,
    p_row_grain TEXT,
    p_wunpaid TEXT,
    p_amount_basis TEXT,
    p_calculation_version TEXT,
    p_source_endpoint TEXT,
    p_source_fetched_at TIMESTAMPTZ,
    p_source_metadata JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_payload_count INTEGER;
    v_payload_omzet NUMERIC;
    v_persisted_count INTEGER;
    v_persisted_omzet NUMERIC;
    v_existing_fetched_at TIMESTAMPTZ;
    v_synced_at TIMESTAMPTZ := NOW();
BEGIN
    IF COALESCE(BTRIM(p_source_scope), '') = '' OR LENGTH(p_source_scope) > 128 THEN
        RAISE EXCEPTION 'source_scope wajib diisi dan maksimal 128 karakter';
    END IF;

    IF p_business_date IS NULL THEN
        RAISE EXCEPTION 'business_date wajib diisi';
    END IF;

    IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'rows harus berupa JSON array';
    END IF;

    IF p_report_row_count IS NULL OR p_report_row_count < 0 THEN
        RAISE EXCEPTION 'report_row_count tidak valid';
    END IF;

    IF p_page_count IS NULL OR p_page_count < 1 THEN
        RAISE EXCEPTION 'page_count harus minimal 1';
    END IF;

    IF COALESCE(BTRIM(p_revenue_field), '') = '' THEN
        RAISE EXCEPTION 'revenue_field wajib diisi';
    END IF;

    IF jsonb_typeof(p_record_key_fields) IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_record_key_fields) = 0
       OR EXISTS (
            SELECT 1
            FROM jsonb_array_elements(p_record_key_fields) AS key_field(value)
            WHERE jsonb_typeof(key_field.value) <> 'string'
               OR COALESCE(BTRIM(key_field.value #>> '{}'), '') = ''
       ) THEN
        RAISE EXCEPTION 'record_key_fields harus berupa array string non-kosong';
    END IF;

    IF COALESCE(BTRIM(p_row_grain), '') = '' THEN
        RAISE EXCEPTION 'row_grain wajib diisi';
    END IF;

    IF p_wunpaid IS NULL OR p_wunpaid NOT IN ('0', '1') THEN
        RAISE EXCEPTION 'wunpaid wajib 0 atau 1 setelah diverifikasi dengan data nyata';
    END IF;

    IF COALESCE(BTRIM(p_amount_basis), '') = '' THEN
        RAISE EXCEPTION 'amount_basis wajib diisi';
    END IF;

    IF COALESCE(BTRIM(p_calculation_version), '') = '' THEN
        RAISE EXCEPTION 'calculation_version wajib diisi';
    END IF;

    IF COALESCE(BTRIM(p_source_endpoint), '') = ''
       OR p_source_endpoint !~ '^https://' THEN
        RAISE EXCEPTION 'source_endpoint wajib berupa URL HTTPS';
    END IF;

    IF p_source_fetched_at IS NULL THEN
        RAISE EXCEPTION 'source_fetched_at wajib diisi';
    END IF;

    IF jsonb_typeof(p_source_metadata) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'source_metadata harus berupa JSON array';
    END IF;

    IF jsonb_array_length(p_source_metadata) <> p_page_count THEN
        RAISE EXCEPTION
            'page_count tidak cocok: metadata %, parameter %',
            jsonb_array_length(p_source_metadata),
            p_page_count;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_source_metadata) AS metadata(value)
        WHERE jsonb_typeof(metadata.value) <> 'object'
    ) THEN
        RAISE EXCEPTION 'setiap source_metadata harus berupa object';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_rows) AS entry(value)
        WHERE jsonb_typeof(entry.value) <> 'object'
           OR jsonb_typeof(entry.value -> 'raw_payload') IS DISTINCT FROM 'object'
           OR COALESCE(BTRIM(entry.value ->> 'record_key'), '') = ''
           OR LENGTH(entry.value ->> 'record_key') > 320
           OR OCTET_LENGTH(entry.value ->> 'record_key') > 1000
           OR jsonb_typeof(entry.value -> 'revenue_amount') IS DISTINCT FROM 'string'
           OR (entry.value ->> 'revenue_amount') !~ '^-?[0-9]+(\.[0-9]+)?$'
           OR LENGTH(entry.value ->> 'revenue_amount') > 64
    ) THEN
        RAISE EXCEPTION 'baris normalisasi tidak valid';
    END IF;

    SELECT
        COUNT(*)::INTEGER,
        COALESCE(SUM((entry.value ->> 'revenue_amount')::NUMERIC), 0)
    INTO v_payload_count, v_payload_omzet
    FROM jsonb_array_elements(p_rows) AS entry(value);

    IF v_payload_count <> p_report_row_count THEN
        RAISE EXCEPTION
            'report_row_count tidak cocok: payload %, parameter %',
            v_payload_count,
            p_report_row_count;
    END IF;

    IF (
        SELECT COUNT(DISTINCT entry.value ->> 'record_key')
        FROM jsonb_array_elements(p_rows) AS entry(value)
    ) <> v_payload_count THEN
        RAISE EXCEPTION 'record_key ganda ditemukan pada snapshot';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtext(p_source_scope),
        (p_business_date - DATE '2000-01-01')::INTEGER
    );

    SELECT daily.source_fetched_at
    INTO v_existing_fetched_at
    FROM public.olsera_daily_revenue AS daily
    WHERE daily.source_scope = p_source_scope
      AND daily.business_date = p_business_date;

    IF FOUND AND v_existing_fetched_at > p_source_fetched_at THEN
        RETURN jsonb_build_object(
            'status', 'SKIPPED_STALE',
            'source_scope', p_source_scope,
            'business_date', p_business_date,
            'existing_source_fetched_at', v_existing_fetched_at,
            'incoming_source_fetched_at', p_source_fetched_at
        );
    END IF;

    INSERT INTO public.olsera_sales_detail_rows (
        source_scope,
        business_date,
        record_key,
        order_id,
        order_no,
        source_timestamp_raw,
        status,
        payment_status,
        payment_method,
        customer_id,
        store_id,
        revenue_amount,
        revenue_field,
        row_grain,
        calculation_version,
        raw_payload,
        first_seen_at,
        synced_at
    )
    SELECT
        p_source_scope,
        p_business_date,
        entry.value ->> 'record_key',
        NULLIF(BTRIM(entry.value ->> 'order_id'), ''),
        NULLIF(BTRIM(entry.value ->> 'order_no'), ''),
        NULLIF(entry.value ->> 'source_timestamp_raw', ''),
        NULLIF(BTRIM(entry.value ->> 'status'), ''),
        NULLIF(BTRIM(entry.value ->> 'payment_status'), ''),
        NULLIF(BTRIM(entry.value ->> 'payment_method'), ''),
        NULLIF(BTRIM(entry.value ->> 'customer_id'), ''),
        NULLIF(BTRIM(entry.value ->> 'store_id'), ''),
        (entry.value ->> 'revenue_amount')::NUMERIC,
        p_revenue_field,
        p_row_grain,
        p_calculation_version,
        entry.value -> 'raw_payload',
        v_synced_at,
        v_synced_at
    FROM jsonb_array_elements(p_rows) AS entry(value)
    ORDER BY entry.value ->> 'record_key'
    ON CONFLICT (source_scope, business_date, record_key) DO UPDATE SET
        order_id = EXCLUDED.order_id,
        order_no = EXCLUDED.order_no,
        source_timestamp_raw = EXCLUDED.source_timestamp_raw,
        status = EXCLUDED.status,
        payment_status = EXCLUDED.payment_status,
        payment_method = EXCLUDED.payment_method,
        customer_id = EXCLUDED.customer_id,
        store_id = EXCLUDED.store_id,
        revenue_amount = EXCLUDED.revenue_amount,
        revenue_field = EXCLUDED.revenue_field,
        row_grain = EXCLUDED.row_grain,
        calculation_version = EXCLUDED.calculation_version,
        raw_payload = EXCLUDED.raw_payload,
        synced_at = EXCLUDED.synced_at;

    DELETE FROM public.olsera_sales_detail_rows AS existing
    WHERE existing.source_scope = p_source_scope
      AND existing.business_date = p_business_date
      AND NOT EXISTS (
          SELECT 1
          FROM jsonb_array_elements(p_rows) AS entry(value)
          WHERE existing.record_key = entry.value ->> 'record_key'
      );

    SELECT
        COUNT(*)::INTEGER,
        COALESCE(SUM(revenue_amount), 0)
    INTO v_persisted_count, v_persisted_omzet
    FROM public.olsera_sales_detail_rows
    WHERE source_scope = p_source_scope
      AND business_date = p_business_date;

    IF v_persisted_count <> v_payload_count
       OR v_persisted_omzet <> v_payload_omzet THEN
        RAISE EXCEPTION
            'invariant snapshot gagal: rows %/%, omzet %/%',
            v_persisted_count,
            v_payload_count,
            v_persisted_omzet,
            v_payload_omzet;
    END IF;

    INSERT INTO public.olsera_daily_revenue (
        source_scope,
        business_date,
        omzet,
        report_row_count,
        page_count,
        revenue_field,
        record_key_fields,
        row_grain,
        wunpaid,
        amount_basis,
        calculation_version,
        source_endpoint,
        source_fetched_at,
        source_metadata,
        synced_at
    ) VALUES (
        p_source_scope,
        p_business_date,
        v_persisted_omzet,
        v_persisted_count,
        p_page_count,
        p_revenue_field,
        p_record_key_fields,
        p_row_grain,
        p_wunpaid,
        p_amount_basis,
        p_calculation_version,
        p_source_endpoint,
        p_source_fetched_at,
        p_source_metadata,
        v_synced_at
    )
    ON CONFLICT (source_scope, business_date) DO UPDATE SET
        omzet = EXCLUDED.omzet,
        report_row_count = EXCLUDED.report_row_count,
        page_count = EXCLUDED.page_count,
        revenue_field = EXCLUDED.revenue_field,
        record_key_fields = EXCLUDED.record_key_fields,
        row_grain = EXCLUDED.row_grain,
        wunpaid = EXCLUDED.wunpaid,
        amount_basis = EXCLUDED.amount_basis,
        calculation_version = EXCLUDED.calculation_version,
        source_endpoint = EXCLUDED.source_endpoint,
        source_fetched_at = EXCLUDED.source_fetched_at,
        source_metadata = EXCLUDED.source_metadata,
        synced_at = EXCLUDED.synced_at;

    RETURN jsonb_build_object(
        'status', 'UPSERTED',
        'source_scope', p_source_scope,
        'business_date', p_business_date,
        'omzet', v_persisted_omzet::TEXT,
        'report_row_count', v_persisted_count,
        'page_count', p_page_count,
        'revenue_field', p_revenue_field,
        'source_fetched_at', p_source_fetched_at,
        'synced_at', v_synced_at
    );
END;
$$;

CREATE OR REPLACE VIEW public.v_olsera_daily_revenue AS
SELECT
    source_scope,
    business_date,
    omzet,
    report_row_count,
    page_count,
    revenue_field,
    row_grain,
    wunpaid,
    amount_basis,
    calculation_version,
    source_fetched_at,
    synced_at
FROM public.olsera_daily_revenue;

CREATE OR REPLACE VIEW public.v_olsera_sales_by_payment_method AS
SELECT
    source_scope,
    business_date,
    COALESCE(NULLIF(BTRIM(payment_method), ''), 'Lainnya / Tidak Disebutkan') AS payment_method,
    COUNT(*)::INTEGER AS transaction_count,
    COALESCE(SUM(revenue_amount), 0)::NUMERIC AS total_revenue,
    MIN(source_timestamp_raw) AS min_timestamp,
    MAX(source_timestamp_raw) AS max_timestamp
FROM public.olsera_sales_detail_rows
GROUP BY source_scope, business_date, COALESCE(NULLIF(BTRIM(payment_method), ''), 'Lainnya / Tidak Disebutkan');

COMMENT ON VIEW public.v_olsera_sales_by_payment_method IS
    'Aggregated daily revenue and transaction count per payment method for reporting and dashboards.';

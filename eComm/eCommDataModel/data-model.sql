-- =============================================================================
-- eCommerce Platform — Full PostgreSQL DDL
-- Multi-tenant · Multi-store · Catalog · Pricing · Inventory
-- =============================================================================
-- Service boundaries:
--   tenant_svc     → tenants, stores
--   catalog_svc    → catalogs, categories, products, product_variants,
--                     product_attributes, catalog_products, category_products
--   pricing_svc    → price_books, price_book_entries
--   assortment_svc → store_products
--   inventory_svc  → inventory
--   customer_svc   → customers
--   order_svc      → orders, order_items, order_promotions
--   promotion_svc  → promotions, config_entries, promotion_redemptions
--
-- Cross-service FKs are intentionally absent — enforced at the application
-- layer only (event-driven consistency).
-- =============================================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "citext";     -- case-insensitive text


-- =============================================================================
-- SCHEMA: tenant_svc
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS tenant_svc;

-- ── Tenants ──────────────────────────────────────────────────────────────────
CREATE TABLE tenant_svc.tenants (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    name            varchar(255)    NOT NULL,
    slug            citext          NOT NULL,
    locale          varchar(10)     NOT NULL DEFAULT 'en-US',   -- e.g. fr-FR
    currency_code   char(3)         NOT NULL DEFAULT 'EUR',
    address_line1   varchar(255),
    address_line2   varchar(255),
    city            varchar(100),
    state_province  varchar(100),
    postal_code     varchar(20),
    country_code    char(2)         NOT NULL,
    phone           varchar(30),
    email           varchar(255),
    -- logical refs to other services (no FK constraint)
    catalog_id              uuid,   -- → catalog_svc.catalogs.id
    default_price_book_id   uuid,   -- → pricing_svc.price_books.id
    status          varchar(20)     NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','SUSPENDED','ARCHIVED')),
    settings        jsonb           NOT NULL DEFAULT '{}',
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX tenants_slug_uidx ON tenant_svc.tenants (slug);

-- ── Stores (locations) ───────────────────────────────────────────────────────
CREATE TABLE tenant_svc.stores (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid            NOT NULL REFERENCES tenant_svc.tenants (id),
    code            varchar(50)     NOT NULL,       -- internal branch number
    name            varchar(255)    NOT NULL,
    address_line1   varchar(255),
    address_line2   varchar(255),
    city            varchar(100),
    state_province  varchar(100),
    postal_code     varchar(20),
    country_code    char(2),
    phone           varchar(30),
    email           varchar(255),
    -- every store must have exactly one price book (may be shared)
    price_book_id   uuid            NOT NULL,       -- → pricing_svc.price_books.id
    status          varchar(20)     NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','INACTIVE','CLOSED')),
    settings        jsonb           NOT NULL DEFAULT '{}',
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX stores_tenant_code_uidx ON tenant_svc.stores (tenant_id, code);
CREATE INDEX stores_tenant_id_idx         ON tenant_svc.stores (tenant_id);
CREATE INDEX stores_price_book_id_idx     ON tenant_svc.stores (price_book_id);


-- =============================================================================
-- SCHEMA: catalog_svc
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS catalog_svc;

-- ── Catalogs (one per tenant) ─────────────────────────────────────────────────
CREATE TABLE catalog_svc.catalogs (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid            NOT NULL,       -- → tenant_svc.tenants.id
    name            varchar(255)    NOT NULL,
    locale          varchar(10)     NOT NULL,       -- mirrors tenants.locale
    currency_code   char(3)         NOT NULL,       -- mirrors tenants.currency_code
    status          varchar(20)     NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','ARCHIVED')),
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now()
);

-- one catalog per tenant
CREATE UNIQUE INDEX catalogs_tenant_uidx ON catalog_svc.catalogs (tenant_id);

-- ── Categories (self-referencing tree) ────────────────────────────────────────
CREATE TABLE catalog_svc.categories (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    catalog_id      uuid            NOT NULL REFERENCES catalog_svc.catalogs (id),
    parent_id       uuid            REFERENCES catalog_svc.categories (id),
    code            varchar(100)    NOT NULL,
    name            varchar(255)    NOT NULL,
    sort_order      integer         NOT NULL DEFAULT 0,
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX categories_catalog_code_uidx ON catalog_svc.categories (catalog_id, code);
CREATE INDEX categories_parent_id_idx            ON catalog_svc.categories (parent_id);
CREATE INDEX categories_catalog_id_idx           ON catalog_svc.categories (catalog_id);

-- ── Products (master — catalog-scoped) ────────────────────────────────────────
CREATE TABLE catalog_svc.products (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    catalog_id      uuid            NOT NULL REFERENCES catalog_svc.catalogs (id),
    sku             varchar(100)    NOT NULL,
    name            varchar(255)    NOT NULL,
    description     text,
    brand           varchar(100),
    status          varchar(20)     NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('DRAFT','ACTIVE','DISCONTINUED')),
    attributes      jsonb           NOT NULL DEFAULT '{}',
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX products_catalog_sku_uidx ON catalog_svc.products (catalog_id, sku);
CREATE INDEX products_catalog_id_idx          ON catalog_svc.products (catalog_id);
CREATE INDEX products_brand_idx               ON catalog_svc.products (brand);
CREATE INDEX products_status_idx              ON catalog_svc.products (status);
CREATE INDEX products_attributes_idx          ON catalog_svc.products USING gin (attributes);

-- ── Product Variants (sellable SKUs) ──────────────────────────────────────────
CREATE TABLE catalog_svc.product_variants (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id      uuid            NOT NULL REFERENCES catalog_svc.products (id),
    sku             varchar(100)    NOT NULL,
    name            varchar(255),
    -- structured variant attributes (e.g. {"tire_size":"205/55R16","load_index":"91"})
    attributes      jsonb           NOT NULL DEFAULT '{}',
    status          varchar(20)     NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','DISCONTINUED')),
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX variants_product_sku_uidx ON catalog_svc.product_variants (product_id, sku);
CREATE INDEX variants_product_id_idx          ON catalog_svc.product_variants (product_id);
CREATE INDEX variants_attributes_idx          ON catalog_svc.product_variants USING gin (attributes);

-- ── Product Attributes (structured — searchable) ──────────────────────────────
CREATE TABLE catalog_svc.product_attributes (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id      uuid            NOT NULL REFERENCES catalog_svc.products (id),
    variant_id      uuid            REFERENCES catalog_svc.product_variants (id),  -- NULL = product-level
    key             varchar(100)    NOT NULL,
    value           varchar(1000)   NOT NULL,
    created_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE INDEX prod_attrs_product_id_idx ON catalog_svc.product_attributes (product_id);
CREATE INDEX prod_attrs_variant_id_idx ON catalog_svc.product_attributes (variant_id);
CREATE INDEX prod_attrs_key_idx        ON catalog_svc.product_attributes (key);

-- ── Catalog Products (catalog membership) ────────────────────────────────────
CREATE TABLE catalog_svc.catalog_products (
    catalog_id      uuid            NOT NULL REFERENCES catalog_svc.catalogs (id),
    product_id      uuid            NOT NULL REFERENCES catalog_svc.products (id),
    is_published    boolean         NOT NULL DEFAULT false,
    published_at    timestamptz,
    PRIMARY KEY (catalog_id, product_id)
);

CREATE INDEX catalog_products_product_id_idx ON catalog_svc.catalog_products (product_id);

-- ── Category Products (category membership) ───────────────────────────────────
CREATE TABLE catalog_svc.category_products (
    category_id     uuid            NOT NULL REFERENCES catalog_svc.categories (id),
    product_id      uuid            NOT NULL REFERENCES catalog_svc.products (id),
    sort_order      integer         NOT NULL DEFAULT 0,
    PRIMARY KEY (category_id, product_id)
);

CREATE INDEX cat_products_product_id_idx ON catalog_svc.category_products (product_id);


-- =============================================================================
-- SCHEMA: pricing_svc
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS pricing_svc;

-- ── Price Books ───────────────────────────────────────────────────────────────
-- Many stores can share one price book.
CREATE TABLE pricing_svc.price_books (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid            NOT NULL,       -- → tenant_svc.tenants.id
    code            varchar(100)    NOT NULL,
    name            varchar(255)    NOT NULL,
    currency_code   char(3)         NOT NULL DEFAULT 'EUR',
    status          varchar(20)     NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','ARCHIVED')),
    valid_from      timestamptz,
    valid_until     timestamptz,
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now(),
    CONSTRAINT price_books_validity_chk CHECK (
        valid_until IS NULL OR valid_until > valid_from
    )
);

CREATE UNIQUE INDEX price_books_tenant_code_uidx ON pricing_svc.price_books (tenant_id, code);
CREATE INDEX price_books_tenant_id_idx           ON pricing_svc.price_books (tenant_id);

-- ── Price Book Entries ────────────────────────────────────────────────────────
-- Priced at variant level; variant_id IS NULL means base product price fallback.
CREATE TABLE pricing_svc.price_book_entries (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    price_book_id       uuid        NOT NULL REFERENCES pricing_svc.price_books (id),
    product_id          uuid        NOT NULL,       -- → catalog_svc.products.id
    variant_id          uuid,                       -- → catalog_svc.product_variants.id; NULL = base price
    price               numeric(12,4) NOT NULL CHECK (price >= 0),
    compare_at_price    numeric(12,4) CHECK (compare_at_price IS NULL OR compare_at_price > price),
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

-- one price per (price_book, product, variant) — variant_id can be NULL (use IS NOT DISTINCT FROM)
CREATE UNIQUE INDEX price_entries_book_prod_var_uidx
    ON pricing_svc.price_book_entries (price_book_id, product_id, (variant_id IS NULL), variant_id)
    WHERE variant_id IS NOT NULL;
CREATE UNIQUE INDEX price_entries_book_prod_base_uidx
    ON pricing_svc.price_book_entries (price_book_id, product_id)
    WHERE variant_id IS NULL;

CREATE INDEX price_entries_price_book_id_idx ON pricing_svc.price_book_entries (price_book_id);
CREATE INDEX price_entries_product_id_idx    ON pricing_svc.price_book_entries (product_id);
CREATE INDEX price_entries_variant_id_idx    ON pricing_svc.price_book_entries (variant_id);


-- =============================================================================
-- SCHEMA: assortment_svc
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS assortment_svc;

-- ── Store Products (opt-in assortment) ───────────────────────────────────────
-- A product row must exist here for a store to sell it.
-- variant_id IS NULL  → applies to all variants of the product.
-- variant_id IS SET   → variant-level override.
CREATE TABLE assortment_svc.store_products (
    store_id        uuid            NOT NULL,   -- → tenant_svc.stores.id
    product_id      uuid            NOT NULL,   -- → catalog_svc.products.id
    variant_id      uuid,                       -- → catalog_svc.product_variants.id
    is_available    boolean         NOT NULL DEFAULT true,
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now(),
    PRIMARY KEY (store_id, product_id, (variant_id IS NULL), COALESCE(variant_id, '00000000-0000-0000-0000-000000000000'))
);

CREATE INDEX store_products_store_id_idx    ON assortment_svc.store_products (store_id);
CREATE INDEX store_products_product_id_idx  ON assortment_svc.store_products (product_id);
CREATE INDEX store_products_variant_id_idx  ON assortment_svc.store_products (variant_id);


-- =============================================================================
-- SCHEMA: inventory_svc
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS inventory_svc;

-- ── Inventory (per store, per variant) ───────────────────────────────────────
CREATE TABLE inventory_svc.inventory (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id        uuid            NOT NULL,   -- → tenant_svc.stores.id
    variant_id      uuid            NOT NULL,   -- → catalog_svc.product_variants.id
    qty_on_hand     integer         NOT NULL DEFAULT 0 CHECK (qty_on_hand >= 0),
    qty_reserved    integer         NOT NULL DEFAULT 0 CHECK (qty_reserved >= 0),
    reorder_point   integer         NOT NULL DEFAULT 0,
    updated_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX inventory_store_variant_uidx ON inventory_svc.inventory (store_id, variant_id);
CREATE INDEX inventory_store_id_idx              ON inventory_svc.inventory (store_id);
CREATE INDEX inventory_variant_id_idx            ON inventory_svc.inventory (variant_id);


-- =============================================================================
-- USEFUL VIEWS (cross-service — read-only query helpers)
-- =============================================================================

-- Resolve the price for a given store + product + variant
-- Usage: SELECT * FROM store_effective_price WHERE store_id = $1 AND product_id = $2
CREATE OR REPLACE VIEW pricing_svc.store_effective_price AS
SELECT
    s.id                    AS store_id,
    s.tenant_id,
    s.price_book_id,
    e.product_id,
    e.variant_id,
    e.price,
    e.compare_at_price,
    pb.currency_code
FROM tenant_svc.stores            s
JOIN pricing_svc.price_books      pb ON pb.id = s.price_book_id
JOIN pricing_svc.price_book_entries e ON e.price_book_id = pb.id
WHERE pb.status = 'ACTIVE'
  AND (pb.valid_from  IS NULL OR pb.valid_from  <= now())
  AND (pb.valid_until IS NULL OR pb.valid_until >  now());

-- Available stock per store per variant (on-hand minus reserved)
CREATE OR REPLACE VIEW inventory_svc.available_stock AS
SELECT
    store_id,
    variant_id,
    qty_on_hand - qty_reserved AS qty_available,
    qty_on_hand,
    qty_reserved,
    updated_at
FROM inventory_svc.inventory;


-- =============================================================================
-- UPDATED_AT trigger (applied to all tables that carry the column)
-- =============================================================================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DO $$
DECLARE
  tbl record;
BEGIN
  FOR tbl IN
    SELECT schemaname, tablename
    FROM pg_tables
    WHERE schemaname IN ('tenant_svc','catalog_svc','pricing_svc','assortment_svc','inventory_svc')
  LOOP
    IF EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = tbl.schemaname
        AND table_name   = tbl.tablename
        AND column_name  = 'updated_at'
    ) THEN
      EXECUTE format(
        'CREATE OR REPLACE TRIGGER trg_set_updated_at
         BEFORE UPDATE ON %I.%I
         FOR EACH ROW EXECUTE FUNCTION set_updated_at()',
        tbl.schemaname, tbl.tablename
      );
    END IF;
  END LOOP;
END;
$$;


-- =============================================================================
-- SCHEMA: customer_svc
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS customer_svc;

-- ── Customers ────────────────────────────────────────────────────────────────
CREATE TABLE customer_svc.customers (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid            NOT NULL,           -- → tenant_svc.tenants.id
    external_id     varchar(100),                       -- CRM / loyalty system ref
    email           citext          NOT NULL,
    first_name      varchar(100),
    last_name       varchar(100),
    phone           varchar(30),
    tier            varchar(20)     NOT NULL DEFAULT 'STANDARD'
                        CHECK (tier IN ('STANDARD','SILVER','GOLD','PLATINUM')),
    new_customer    boolean         NOT NULL DEFAULT true,
    locale          varchar(10),                        -- override tenant locale (e.g. for expat customers)
    status          varchar(20)     NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
    settings        jsonb           NOT NULL DEFAULT '{}',
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX customers_tenant_email_uidx ON customer_svc.customers (tenant_id, email);
CREATE INDEX customers_tenant_id_idx            ON customer_svc.customers (tenant_id);
CREATE INDEX customers_tier_idx                 ON customer_svc.customers (tier);
CREATE INDEX customers_external_id_idx          ON customer_svc.customers (external_id);


-- =============================================================================
-- SCHEMA: order_svc
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS order_svc;

-- ── Orders ───────────────────────────────────────────────────────────────────
CREATE TABLE order_svc.orders (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid            NOT NULL,           -- → tenant_svc.tenants.id
    store_id        uuid            NOT NULL,           -- → tenant_svc.stores.id
    customer_id     uuid,                               -- → customer_svc.customers.id; NULL = guest
    cart_id         varchar(100)    NOT NULL,           -- originating cart ref
    status          varchar(30)     NOT NULL DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING','CONFIRMED','PROCESSING','SHIPPED','DELIVERED','CANCELLED','REFUNDED')),
    currency_code   char(3)         NOT NULL DEFAULT 'EUR',
    subtotal        numeric(12,4)   NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    discount_total  numeric(12,4)   NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
    grand_total     numeric(12,4)   NOT NULL DEFAULT 0 CHECK (grand_total >= 0),
    coupon_code     varchar(100),
    notes           text,
    placed_at       timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE INDEX orders_tenant_id_idx    ON order_svc.orders (tenant_id);
CREATE INDEX orders_store_id_idx     ON order_svc.orders (store_id);
CREATE INDEX orders_customer_id_idx  ON order_svc.orders (customer_id);
CREATE INDEX orders_status_idx       ON order_svc.orders (status);
CREATE INDEX orders_placed_at_idx    ON order_svc.orders (placed_at);

-- ── Order Line Items ─────────────────────────────────────────────────────────
CREATE TABLE order_svc.order_items (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id        uuid            NOT NULL REFERENCES order_svc.orders (id),
    product_id      uuid            NOT NULL,           -- → catalog_svc.products.id
    variant_id      uuid,                               -- → catalog_svc.product_variants.id
    sku             varchar(100)    NOT NULL,
    product_name    varchar(255)    NOT NULL,
    category        varchar(100)    NOT NULL,
    quantity        integer         NOT NULL CHECK (quantity > 0),
    unit_price      numeric(12,4)   NOT NULL CHECK (unit_price >= 0),
    line_discount   numeric(12,4)   NOT NULL DEFAULT 0 CHECK (line_discount >= 0),
    line_total      numeric(12,4)   NOT NULL CHECK (line_total >= 0)   -- (unit_price * qty) - line_discount
);

CREATE INDEX order_items_order_id_idx   ON order_svc.order_items (order_id);
CREATE INDEX order_items_product_id_idx ON order_svc.order_items (product_id);
CREATE INDEX order_items_variant_id_idx ON order_svc.order_items (variant_id);

-- ── Applied Promotions (per order) ───────────────────────────────────────────
CREATE TABLE order_svc.order_promotions (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id        uuid            NOT NULL REFERENCES order_svc.orders (id),
    promotion_id    bigint          NOT NULL,           -- → promotion_svc.promotions.id
    promotion_code  varchar(100)    NOT NULL,
    discount_amount numeric(12,4)   NOT NULL CHECK (discount_amount >= 0),
    applied_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE INDEX order_promotions_order_id_idx     ON order_svc.order_promotions (order_id);
CREATE INDEX order_promotions_promotion_id_idx ON order_svc.order_promotions (promotion_id);


-- =============================================================================
-- SCHEMA: promotion_svc
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS promotion_svc;

-- ── Promotions (mirrors promotion-engine JPA entity) ─────────────────────────
CREATE TABLE promotion_svc.promotions (
    id                      bigserial       PRIMARY KEY,
    code                    varchar(100)    NOT NULL,
    name                    varchar(255)    NOT NULL,
    description             text,
    type                    varchar(30)     NOT NULL
                                CHECK (type IN ('ORDER_DISCOUNT','ITEM_DISCOUNT')),
    parameters              text,           -- JSON: discountType, condition, threshold, percentage, amount, etc.
    agenda_group            varchar(50),    -- Drools agenda group: 'order' | 'item'
    salience                integer         NOT NULL DEFAULT 10,
    stackable               boolean         NOT NULL DEFAULT true,
    tenant_id               varchar(100)    NOT NULL DEFAULT 'ALL',
    store_number            varchar(100)    NOT NULL DEFAULT 'ALL',
    requires_coupon         boolean         NOT NULL DEFAULT false,
    required_coupon_code    varchar(100),
    included_categories     varchar(1000),  -- comma-separated whitelist
    excluded_categories     varchar(1000),  -- comma-separated blacklist
    included_skus           varchar(2000),
    excluded_skus           varchar(2000),
    enabled                 boolean         NOT NULL DEFAULT true,
    created_at              timestamptz     NOT NULL DEFAULT now(),
    updated_at              timestamptz     NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX promotions_code_uidx       ON promotion_svc.promotions (code);
CREATE INDEX promotions_tenant_id_idx          ON promotion_svc.promotions (tenant_id);
CREATE INDEX promotions_store_number_idx       ON promotion_svc.promotions (store_number);
CREATE INDEX promotions_enabled_idx            ON promotion_svc.promotions (enabled);

-- ── Config Entries (reference data: tenants, stores, categories, conditions) ─
CREATE TABLE promotion_svc.config_entries (
    id              bigserial       PRIMARY KEY,
    config_type     varchar(50)     NOT NULL,   -- 'TENANT' | 'STORE' | 'CATEGORY' | 'ORDER_CONDITION'
    entry_value     varchar(500)    NOT NULL,
    label           varchar(255),
    description     text,
    requires_input  boolean         NOT NULL DEFAULT false,
    sort_order      integer         NOT NULL DEFAULT 0,
    enabled         boolean         NOT NULL DEFAULT true
);

CREATE INDEX config_entries_type_idx ON promotion_svc.config_entries (config_type, enabled);

-- ── Promotion Redemptions (audit trail) ──────────────────────────────────────
CREATE TABLE promotion_svc.promotion_redemptions (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    promotion_id    bigint          NOT NULL REFERENCES promotion_svc.promotions (id),
    order_id        uuid            NOT NULL,           -- → order_svc.orders.id
    customer_id     uuid,                               -- → customer_svc.customers.id; NULL = guest
    tenant_id       varchar(100)    NOT NULL,
    store_number    varchar(100),
    discount_amount numeric(12,4)   NOT NULL CHECK (discount_amount >= 0),
    coupon_code     varchar(100),
    redeemed_at     timestamptz     NOT NULL DEFAULT now()
);

CREATE INDEX redemptions_promotion_id_idx ON promotion_svc.promotion_redemptions (promotion_id);
CREATE INDEX redemptions_order_id_idx     ON promotion_svc.promotion_redemptions (order_id);
CREATE INDEX redemptions_customer_id_idx  ON promotion_svc.promotion_redemptions (customer_id);
CREATE INDEX redemptions_tenant_id_idx    ON promotion_svc.promotion_redemptions (tenant_id);
CREATE INDEX redemptions_redeemed_at_idx  ON promotion_svc.promotion_redemptions (redeemed_at);


-- =============================================================================
-- SEED DATA — Tenant: Speedy France
-- =============================================================================

INSERT INTO tenant_svc.tenants (
    id, name, slug, locale, currency_code, country_code, email, status
) VALUES (
    'a1000000-0000-0000-0000-000000000001',
    'Speedy France',
    'speedy-france',
    'fr-FR',
    'EUR',
    'FR',
    'contact@speedy.fr',
    'ACTIVE'
);

INSERT INTO catalog_svc.catalogs (
    id, tenant_id, name, locale, currency_code, status
) VALUES (
    'b1000000-0000-0000-0000-000000000001',
    'a1000000-0000-0000-0000-000000000001',
    'Speedy France Catalogue',
    'fr-FR',
    'EUR',
    'ACTIVE'
);

-- Update tenant with catalog_id back-ref
UPDATE tenant_svc.tenants
SET catalog_id = 'b1000000-0000-0000-0000-000000000001'
WHERE id = 'a1000000-0000-0000-0000-000000000001';

-- Shared price book (IDF region)
INSERT INTO pricing_svc.price_books (
    id, tenant_id, code, name, currency_code, status
) VALUES (
    'c1000000-0000-0000-0000-000000000001',
    'a1000000-0000-0000-0000-000000000001',
    'PB-IDF',
    'Prix Île-de-France',
    'EUR',
    'ACTIVE'
);

-- Update tenant default price book
UPDATE tenant_svc.tenants
SET default_price_book_id = 'c1000000-0000-0000-0000-000000000001'
WHERE id = 'a1000000-0000-0000-0000-000000000001';

-- Two stores sharing the same price book
INSERT INTO tenant_svc.stores (id, tenant_id, code, name, price_book_id, status) VALUES
    ('d1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'SPD-75001', 'Speedy Paris 1er',    'c1000000-0000-0000-0000-000000000001', 'ACTIVE'),
    ('d1000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'SPD-75008', 'Speedy Paris 8ème',   'c1000000-0000-0000-0000-000000000001', 'ACTIVE');

-- Sample category + product
INSERT INTO catalog_svc.categories (id, catalog_id, code, name, sort_order)
VALUES ('e1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'PNEUMATIQUES', 'Pneumatiques', 1);

INSERT INTO catalog_svc.products (id, catalog_id, sku, name, brand, status)
VALUES ('f1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'MICH-PS4-205-55R16', 'Michelin Pilot Sport 4', 'MICHELIN', 'ACTIVE');

INSERT INTO catalog_svc.product_variants (id, product_id, sku, name, attributes)
VALUES ('f2000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'MICH-PS4-205-55R16-91V', '205/55 R16 91V',
        '{"tire_size":"205/55R16","load_index":"91","speed_rating":"V"}');

INSERT INTO catalog_svc.catalog_products (catalog_id, product_id, is_published)
VALUES ('b1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', true);

INSERT INTO catalog_svc.category_products (category_id, product_id)
VALUES ('e1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001');

-- Both stores sell this variant
INSERT INTO assortment_svc.store_products (store_id, product_id, variant_id, is_available) VALUES
    ('d1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'f2000000-0000-0000-0000-000000000001', true),
    ('d1000000-0000-0000-0000-000000000002', 'f1000000-0000-0000-0000-000000000001', 'f2000000-0000-0000-0000-000000000001', true);

-- One price on the shared price book
INSERT INTO pricing_svc.price_book_entries (price_book_id, product_id, variant_id, price, compare_at_price)
VALUES ('c1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'f2000000-0000-0000-0000-000000000001', 89.99, 109.99);

-- Inventory per store
INSERT INTO inventory_svc.inventory (store_id, variant_id, qty_on_hand, qty_reserved, reorder_point) VALUES
    ('d1000000-0000-0000-0000-000000000001', 'f2000000-0000-0000-0000-000000000001', 24, 2, 4),
    ('d1000000-0000-0000-0000-000000000002', 'f2000000-0000-0000-0000-000000000001', 12, 0, 4);

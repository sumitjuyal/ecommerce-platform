-- =============================================================================
-- eCommerce Platform — PostgreSQL DDL
-- Pool DB model: tenant_id as reference column in all schemas
-- =============================================================================
--
-- Architecture: Shared-schema pool model
--   Every table (except tenants itself) carries a tenant_id column.
--   Cross-service foreign keys are LOGICAL only — enforced at the application
--   layer, not the DB layer. Each microservice owns its schema.
--
-- Service boundaries:
--   tenant_svc     → tenants, tenant_settings, stores, store_addresses,
--                    store_hours, store_holiday_hours, tenant_users, tenant_user_roles
--   catalog_svc    → catalogs, categories, products, product_variants,
--                    product_attributes, product_addon_links,
--                    store_product_exclusions
--
-- Planned services (separate schemas, same pool DB):
--   pricing_svc    → price_books, price_book_entries                   (future)
--   customer_svc   → customers                                         (future)
--   order_svc      → orders, order_items                               (future)
--   promotion_svc  → promotions, promotion_redemptions                 (future)
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "citext";     -- case-insensitive text


-- =============================================================================
-- SCHEMA: tenant_svc
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS tenant_svc;

-- ── Tenants ──────────────────────────────────────────────────────────────────
-- The root entity. Every other schema references tenants.id as tenant_id.
CREATE TABLE tenant_svc.tenants (
    id                  uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    slug                citext          NOT NULL,           -- URL-safe identifier, e.g. "speedy-france"
    name                varchar(255)    NOT NULL,           -- display name, e.g. "Speedy France"

    -- Locale & currency
    default_locale      varchar(10)     NOT NULL DEFAULT 'en-US',   -- BCP-47, e.g. fr-FR
    supported_locales   varchar(255)    NOT NULL DEFAULT 'en-US',   -- comma-separated, e.g. fr-FR,en-US
    currency_code       char(3)         NOT NULL DEFAULT 'EUR',      -- ISO 4217

    -- Contact
    email               varchar(255),
    phone               varchar(30),
    website             varchar(255),

    -- Logical references to other services (no FK constraint — pool model)
    catalog_id          uuid,           -- → catalog_svc.catalogs.id

    -- Lifecycle
    status              varchar(20)     NOT NULL DEFAULT 'ACTIVE'
                            CHECK (status IN ('ACTIVE','SUSPENDED','ARCHIVED')),
    plan                varchar(30)     NOT NULL DEFAULT 'STANDARD'
                            CHECK (plan IN ('TRIAL','STANDARD','PROFESSIONAL','ENTERPRISE')),

    created_at          timestamptz     NOT NULL DEFAULT now(),
    updated_at          timestamptz     NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX tenants_slug_uidx ON tenant_svc.tenants (slug);
CREATE INDEX tenants_status_idx       ON tenant_svc.tenants (status);


-- ── Tenant Settings ──────────────────────────────────────────────────────────
-- Key-value config per tenant. Avoids wide nullable columns on tenants table.
-- Examples: timezone, date_format, tax_inclusive_pricing, loyalty_enabled
CREATE TABLE tenant_svc.tenant_settings (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid        NOT NULL REFERENCES tenant_svc.tenants (id) ON DELETE CASCADE,
    key         varchar(100)    NOT NULL,
    value       text            NOT NULL,
    created_at  timestamptz     NOT NULL DEFAULT now(),
    updated_at  timestamptz     NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX tenant_settings_tenant_key_uidx ON tenant_svc.tenant_settings (tenant_id, key);
CREATE INDEX tenant_settings_tenant_id_idx          ON tenant_svc.tenant_settings (tenant_id);


-- ── Stores (physical or virtual locations per tenant) ────────────────────────
CREATE TABLE tenant_svc.stores (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid            NOT NULL REFERENCES tenant_svc.tenants (id),
    code            varchar(50)     NOT NULL,       -- internal branch code, e.g. SPD-75001
    name            varchar(255)    NOT NULL,
    locale          varchar(10),                    -- override tenant default, e.g. fr-FR
    email           varchar(255),
    phone           varchar(30),

    -- Logical reference (no FK — pool model)
    price_book_id   uuid,           -- → pricing_svc.price_books.id

    store_type      varchar(30)     NOT NULL DEFAULT 'PHYSICAL'
                        CHECK (store_type IN ('PHYSICAL','VIRTUAL','FRANCHISE')),
    status          varchar(20)     NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','INACTIVE','CLOSED')),
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX stores_tenant_code_uidx ON tenant_svc.stores (tenant_id, code);
CREATE INDEX stores_tenant_id_idx           ON tenant_svc.stores (tenant_id);
CREATE INDEX stores_status_idx              ON tenant_svc.stores (status);


-- ── Store Addresses ──────────────────────────────────────────────────────────
-- Separated from stores so a store can have multiple addresses
-- (e.g. physical + billing) and the stores table stays clean.
CREATE TABLE tenant_svc.store_addresses (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid            NOT NULL,       -- denormalised for pool queries
    store_id        uuid            NOT NULL REFERENCES tenant_svc.stores (id) ON DELETE CASCADE,
    address_type    varchar(20)     NOT NULL DEFAULT 'PHYSICAL'
                        CHECK (address_type IN ('PHYSICAL','BILLING','MAILING')),
    line1           varchar(255)    NOT NULL,
    line2           varchar(255),
    city            varchar(100)    NOT NULL,
    state_province  varchar(100),
    postal_code     varchar(20),
    country_code    char(2)         NOT NULL,       -- ISO 3166-1 alpha-2
    latitude        numeric(9,6),                   -- for geo/closeness queries
    longitude       numeric(9,6),
    is_primary      boolean         NOT NULL DEFAULT true,
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE INDEX store_addresses_store_id_idx   ON tenant_svc.store_addresses (store_id);
CREATE INDEX store_addresses_tenant_id_idx  ON tenant_svc.store_addresses (tenant_id);
CREATE INDEX store_addresses_geo_idx        ON tenant_svc.store_addresses (latitude, longitude);


-- ── Store Operating Hours ─────────────────────────────────────────────────────
-- One row per day-of-week per store. day_of_week: 0=Sunday … 6=Saturday (ISO: 1=Monday)
CREATE TABLE tenant_svc.store_hours (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid            NOT NULL,       -- denormalised for pool queries
    store_id        uuid            NOT NULL REFERENCES tenant_svc.stores (id) ON DELETE CASCADE,
    day_of_week     smallint        NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
    open_time       time,                           -- NULL = closed this day
    close_time      time,
    is_closed       boolean         NOT NULL DEFAULT false,
    notes           varchar(255),                   -- e.g. "Public holiday hours"
    CONSTRAINT store_hours_times_chk CHECK (
        is_closed = true OR (open_time IS NOT NULL AND close_time IS NOT NULL AND close_time > open_time)
    )
);

CREATE UNIQUE INDEX store_hours_store_day_uidx ON tenant_svc.store_hours (store_id, day_of_week);
CREATE INDEX store_hours_store_id_idx          ON tenant_svc.store_hours (store_id);
CREATE INDEX store_hours_tenant_id_idx         ON tenant_svc.store_hours (tenant_id);


-- ── Store Holiday Hours ───────────────────────────────────────────────────────
-- Overrides store_hours for specific calendar dates (public holidays, special events)
CREATE TABLE tenant_svc.store_holiday_hours (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid            NOT NULL,
    store_id        uuid            NOT NULL REFERENCES tenant_svc.stores (id) ON DELETE CASCADE,
    holiday_date    date            NOT NULL,
    open_time       time,           -- NULL = closed
    close_time      time,
    is_closed       boolean         NOT NULL DEFAULT true,
    description     varchar(255),   -- e.g. "Bastille Day"
    CONSTRAINT store_holiday_times_chk CHECK (
        is_closed = true OR (open_time IS NOT NULL AND close_time IS NOT NULL AND close_time > open_time)
    )
);

CREATE UNIQUE INDEX store_holiday_store_date_uidx ON tenant_svc.store_holiday_hours (store_id, holiday_date);
CREATE INDEX store_holiday_tenant_id_idx          ON tenant_svc.store_holiday_hours (tenant_id);


-- ── Tenant Users ──────────────────────────────────────────────────────────────
-- Back-office users (admins, store managers) belonging to a tenant.
-- End-customers are in customer_svc (separate microservice).
CREATE TABLE tenant_svc.tenant_users (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid            NOT NULL REFERENCES tenant_svc.tenants (id),
    email           citext          NOT NULL,
    first_name      varchar(100),
    last_name       varchar(100),
    status          varchar(20)     NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','INVITED','SUSPENDED','DEACTIVATED')),
    last_login_at   timestamptz,
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX tenant_users_tenant_email_uidx ON tenant_svc.tenant_users (tenant_id, email);
CREATE INDEX tenant_users_tenant_id_idx            ON tenant_svc.tenant_users (tenant_id);


-- ── Tenant User Roles ─────────────────────────────────────────────────────────
-- A user can have different roles, optionally scoped to a specific store.
-- store_id NULL = tenant-wide role.
CREATE TABLE tenant_svc.tenant_user_roles (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid        NOT NULL,
    user_id     uuid        NOT NULL REFERENCES tenant_svc.tenant_users (id) ON DELETE CASCADE,
    store_id    uuid        REFERENCES tenant_svc.stores (id),   -- NULL = tenant-wide
    role        varchar(50) NOT NULL
                    CHECK (role IN ('TENANT_ADMIN','STORE_MANAGER','STORE_STAFF','ANALYST','VIEWER')),
    granted_at  timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX user_roles_user_store_role_uidx
    ON tenant_svc.tenant_user_roles (user_id, role, COALESCE(store_id, '00000000-0000-0000-0000-000000000000'));
CREATE INDEX user_roles_tenant_id_idx ON tenant_svc.tenant_user_roles (tenant_id);
CREATE INDEX user_roles_store_id_idx  ON tenant_svc.tenant_user_roles (store_id);


-- =============================================================================
-- updated_at trigger — applied to all tables with the column
-- =============================================================================
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DO $$
DECLARE tbl record;
BEGIN
  FOR tbl IN
    SELECT schemaname, tablename FROM pg_tables
    WHERE schemaname IN ('tenant_svc','catalog_svc')
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
-- SCHEMA: catalog_svc
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS catalog_svc;

-- ── Catalogs (one per tenant) ─────────────────────────────────────────────────
-- A catalog scopes all products and categories to a tenant.
-- tenant_id here is the logical reference back to tenant_svc.tenants.id
CREATE TABLE catalog_svc.catalogs (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid            NOT NULL UNIQUE,    -- → tenant_svc.tenants.id (logical)
    name            varchar(255)    NOT NULL,
    default_locale  varchar(10)     NOT NULL,           -- mirrors tenants.default_locale
    currency_code   char(3)         NOT NULL,           -- mirrors tenants.currency_code
    status          varchar(20)     NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','ARCHIVED')),
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE INDEX catalogs_tenant_id_idx ON catalog_svc.catalogs (tenant_id);


-- ── Categories (self-referencing tree) ────────────────────────────────────────
-- Supports unlimited depth: TYRES > SUMMER TYRES > PASSENGER TYRES
-- parent_id NULL = root category
CREATE TABLE catalog_svc.categories (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid            NOT NULL,           -- denormalised for pool queries
    catalog_id      uuid            NOT NULL REFERENCES catalog_svc.catalogs (id),
    parent_id       uuid            REFERENCES catalog_svc.categories (id),
    code            varchar(100)    NOT NULL,           -- e.g. TYRES, SERVICES
    name            varchar(255)    NOT NULL,
    description     text,
    image_url       varchar(500),
    sort_order      integer         NOT NULL DEFAULT 0,
    is_active       boolean         NOT NULL DEFAULT true,
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX categories_catalog_code_uidx ON catalog_svc.categories (catalog_id, code);
CREATE INDEX categories_catalog_id_idx           ON catalog_svc.categories (catalog_id);
CREATE INDEX categories_parent_id_idx            ON catalog_svc.categories (parent_id);
CREATE INDEX categories_tenant_id_idx            ON catalog_svc.categories (tenant_id);


-- ── Products (master — catalog-scoped) ────────────────────────────────────────
-- A product is the master record (e.g. "Michelin Pilot Sport 4").
-- Sellable items live in product_variants.
CREATE TABLE catalog_svc.products (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid            NOT NULL,           -- denormalised for pool queries
    catalog_id      uuid            NOT NULL REFERENCES catalog_svc.catalogs (id),
    category_id     uuid            REFERENCES catalog_svc.categories (id),
    sku             varchar(100)    NOT NULL,           -- master SKU
    name            varchar(255)    NOT NULL,
    description     text,
    brand           varchar(100),
    product_type    varchar(30)     NOT NULL DEFAULT 'PRODUCT'
                        CHECK (product_type IN ('PRODUCT','SERVICE','BUNDLE','FEE')),
    status          varchar(20)     NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('DRAFT','ACTIVE','DISCONTINUED')),
    -- SERVICE type products have no variants — price is on the product directly
    base_price      numeric(12,4),
    attributes      jsonb           NOT NULL DEFAULT '{}',  -- flexible key/value bag
    image_url       varchar(500),
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX products_catalog_sku_uidx ON catalog_svc.products (catalog_id, sku);
CREATE INDEX products_tenant_id_idx           ON catalog_svc.products (tenant_id);
CREATE INDEX products_catalog_id_idx          ON catalog_svc.products (catalog_id);
CREATE INDEX products_category_id_idx         ON catalog_svc.products (category_id);
CREATE INDEX products_brand_idx               ON catalog_svc.products (brand);
CREATE INDEX products_status_idx              ON catalog_svc.products (status);
CREATE INDEX products_type_idx                ON catalog_svc.products (product_type);
CREATE INDEX products_attributes_idx          ON catalog_svc.products USING gin (attributes);


-- ── Product Variants (sellable SKUs) ──────────────────────────────────────────
-- One variant = one sellable item (e.g. "Michelin PS4 205/55R16 91V").
-- SERVICE-type products typically have no variants — priced on the product.
CREATE TABLE catalog_svc.product_variants (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid            NOT NULL,           -- denormalised for pool queries
    product_id      uuid            NOT NULL REFERENCES catalog_svc.products (id),
    sku             varchar(100)    NOT NULL,
    name            varchar(255),
    attributes      jsonb           NOT NULL DEFAULT '{}',  -- e.g. {"tire_size":"205/55R16","load":"91"}
    status          varchar(20)     NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','DISCONTINUED')),
    sort_order      integer         NOT NULL DEFAULT 0,
    created_at      timestamptz     NOT NULL DEFAULT now(),
    updated_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX variants_product_sku_uidx ON catalog_svc.product_variants (product_id, sku);
CREATE INDEX variants_tenant_id_idx           ON catalog_svc.product_variants (tenant_id);
CREATE INDEX variants_product_id_idx          ON catalog_svc.product_variants (product_id);
CREATE INDEX variants_attributes_idx          ON catalog_svc.product_variants USING gin (attributes);


-- ── Product Attributes (structured — searchable) ──────────────────────────────
-- Normalised attribute rows for filtering/search (in addition to the jsonb bag).
-- e.g. key=tire_size value=205/55R16, key=load_index value=91
CREATE TABLE catalog_svc.product_attributes (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid            NOT NULL,
    product_id      uuid            NOT NULL REFERENCES catalog_svc.products (id),
    variant_id      uuid            REFERENCES catalog_svc.product_variants (id),  -- NULL = product-level
    key             varchar(100)    NOT NULL,
    value           varchar(500)    NOT NULL,
    created_at      timestamptz     NOT NULL DEFAULT now()
);

CREATE INDEX prod_attrs_product_id_idx  ON catalog_svc.product_attributes (product_id);
CREATE INDEX prod_attrs_variant_id_idx  ON catalog_svc.product_attributes (variant_id);
CREATE INDEX prod_attrs_tenant_id_idx   ON catalog_svc.product_attributes (tenant_id);
CREATE INDEX prod_attrs_key_value_idx   ON catalog_svc.product_attributes (key, value);


-- ── Product Add-on Links ──────────────────────────────────────────────────────
-- Associates a PRODUCT with any add-on: a SERVICE, a physical PRODUCT (part),
-- or a FEE. All three can be mandatory or optional.
--
-- Real example (tyre package):
--   Toyo PROXES ST III          → PRODUCT  (the tyre itself)
--   Computerized Wheel Balance  → SERVICE  is_mandatory=true  (labour)
--   TPMS Valve Service Kit      → PRODUCT  is_mandatory=true  (physical part)
--   TPMS Valve Service Kit Labor→ SERVICE  is_mandatory=true  (labour for above)
--   Scrap Tire Recycling Charge → FEE      is_mandatory=true  (regulatory)
--   State Environmental Fee     → FEE      is_mandatory=true  (regulatory)
--   Shop Supplies               → FEE      is_mandatory=true  (operational)
--   Protection Warranty         → SERVICE  is_mandatory=false (optional upsell)
--
-- is_mandatory = true  → auto-added to cart, customer cannot remove
-- is_mandatory = false → presented as opt-in upsell
-- default_selected     → pre-ticked in UI for optional add-ons
-- sort_order           → controls display order on product page / cart
CREATE TABLE catalog_svc.product_addon_links (
    id                  uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           uuid            NOT NULL,
    product_id          uuid            NOT NULL REFERENCES catalog_svc.products (id),  -- the parent PRODUCT
    addon_id            uuid            NOT NULL REFERENCES catalog_svc.products (id),  -- SERVICE, PRODUCT, or FEE
    is_mandatory        boolean         NOT NULL DEFAULT false,
    default_selected    boolean         NOT NULL DEFAULT false,
    sort_order          integer         NOT NULL DEFAULT 0,
    created_at          timestamptz     NOT NULL DEFAULT now(),
    updated_at          timestamptz     NOT NULL DEFAULT now(),
    CONSTRAINT product_addon_links_different_chk CHECK (product_id <> addon_id)
);

CREATE UNIQUE INDEX prod_addon_links_product_addon_uidx ON catalog_svc.product_addon_links (product_id, addon_id);
CREATE INDEX prod_addon_links_product_id_idx            ON catalog_svc.product_addon_links (product_id);
CREATE INDEX prod_addon_links_tenant_id_idx             ON catalog_svc.product_addon_links (tenant_id);


-- ── Store Product Exclusions (exception-based assortment) ─────────────────────
-- Default = every active product is available at every store.
-- A row here means a store does NOT carry that product/variant.
-- 95% of products available everywhere → almost no rows in this table.
--
-- variant_id NULL  → the whole product (all variants) is excluded for this store.
-- variant_id SET   → only that specific variant is excluded.
CREATE TABLE catalog_svc.store_product_exclusions (
    id              uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid            NOT NULL,           -- denormalised for pool queries
    store_id        uuid            NOT NULL,           -- → tenant_svc.stores.id (logical)
    product_id      uuid            NOT NULL REFERENCES catalog_svc.products (id),
    variant_id      uuid            REFERENCES catalog_svc.product_variants (id),  -- NULL = all variants
    reason          varchar(255),                       -- e.g. "Not stocked at this location"
    excluded_at     timestamptz     NOT NULL DEFAULT now(),
    excluded_by     uuid                                -- → tenant_svc.tenant_users.id (logical)
);

CREATE UNIQUE INDEX exclusions_store_product_var_uidx
    ON catalog_svc.store_product_exclusions (store_id, product_id, COALESCE(variant_id, '00000000-0000-0000-0000-000000000000'));
CREATE INDEX exclusions_tenant_id_idx   ON catalog_svc.store_product_exclusions (tenant_id);
CREATE INDEX exclusions_store_id_idx    ON catalog_svc.store_product_exclusions (store_id);
CREATE INDEX exclusions_product_id_idx  ON catalog_svc.store_product_exclusions (product_id);


-- =============================================================================
-- SEED DATA — Tenant: Speedy France
-- =============================================================================

-- Tenant
INSERT INTO tenant_svc.tenants (id, slug, name, default_locale, supported_locales, currency_code, email, website, status, plan)
VALUES (
    'a1000000-0000-0000-0000-000000000001',
    'speedy-france',
    'Speedy France',
    'fr-FR',
    'fr-FR,en-US',
    'EUR',
    'contact@speedy.fr',
    'https://www.speedy.fr',
    'ACTIVE',
    'PROFESSIONAL'
);

-- Tenant settings
INSERT INTO tenant_svc.tenant_settings (tenant_id, key, value) VALUES
    ('a1000000-0000-0000-0000-000000000001', 'timezone',               'Europe/Paris'),
    ('a1000000-0000-0000-0000-000000000001', 'date_format',            'DD/MM/YYYY'),
    ('a1000000-0000-0000-0000-000000000001', 'tax_inclusive_pricing',  'true'),
    ('a1000000-0000-0000-0000-000000000001', 'loyalty_enabled',        'true');

-- Stores
INSERT INTO tenant_svc.stores (id, tenant_id, code, name, locale, email, phone, store_type, status) VALUES
    ('d1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'SPD-75001', 'Speedy Paris 1er',  'fr-FR', 'paris1@speedy.fr',  '+33 1 40 00 00 01', 'PHYSICAL', 'ACTIVE'),
    ('d1000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'SPD-75008', 'Speedy Paris 8ème', 'fr-FR', 'paris8@speedy.fr',  '+33 1 40 00 00 02', 'PHYSICAL', 'ACTIVE'),
    ('d1000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001', 'SPD-69001', 'Speedy Lyon Centre','fr-FR', 'lyon@speedy.fr',    '+33 4 72 00 00 01', 'PHYSICAL', 'ACTIVE');

-- Store addresses
INSERT INTO tenant_svc.store_addresses (tenant_id, store_id, address_type, line1, city, postal_code, country_code, latitude, longitude, is_primary) VALUES
    ('a1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'PHYSICAL', '12 Rue de Rivoli',       'Paris',  '75001', 'FR',  48.857100,  2.351000, true),
    ('a1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000002', 'PHYSICAL', '45 Avenue des Champs',   'Paris',  '75008', 'FR',  48.872400,  2.302400, true),
    ('a1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000003', 'PHYSICAL', '8 Rue de la République', 'Lyon',   '69001', 'FR',  45.748000,  4.837000, true);

-- Store operating hours (Mon–Fri 08:00–19:00, Sat 09:00–17:00, Sun closed) — Paris 1er
INSERT INTO tenant_svc.store_hours (tenant_id, store_id, day_of_week, open_time, close_time, is_closed) VALUES
    ('a1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 0, NULL,    NULL,    true),   -- Sunday
    ('a1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 1, '08:00', '19:00', false),  -- Monday
    ('a1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 2, '08:00', '19:00', false),  -- Tuesday
    ('a1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 3, '08:00', '19:00', false),  -- Wednesday
    ('a1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 4, '08:00', '19:00', false),  -- Thursday
    ('a1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 5, '08:00', '19:00', false),  -- Friday
    ('a1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 6, '09:00', '17:00', false);  -- Saturday

-- Holiday hours — Paris 1er
INSERT INTO tenant_svc.store_holiday_hours (tenant_id, store_id, holiday_date, is_closed, description) VALUES
    ('a1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', '2026-07-14', true, 'Fête Nationale — Bastille Day'),
    ('a1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', '2026-12-25', true, 'Noël');

-- Tenant admin user
INSERT INTO tenant_svc.tenant_users (id, tenant_id, email, first_name, last_name, status) VALUES
    ('u1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'admin@speedy.fr', 'Admin', 'Speedy', 'ACTIVE');

-- Roles
INSERT INTO tenant_svc.tenant_user_roles (tenant_id, user_id, store_id, role) VALUES
    ('a1000000-0000-0000-0000-000000000001', 'u1000000-0000-0000-0000-000000000001', NULL,                                    'TENANT_ADMIN'),
    ('a1000000-0000-0000-0000-000000000001', 'u1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'STORE_MANAGER');

-- ── Catalog seed ──────────────────────────────────────────────────────────────

INSERT INTO catalog_svc.catalogs (id, tenant_id, name, default_locale, currency_code, status) VALUES
    ('b1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'Speedy France Catalogue', 'fr-FR', 'EUR', 'ACTIVE');

UPDATE tenant_svc.tenants
SET catalog_id = 'b1000000-0000-0000-0000-000000000001'
WHERE id = 'a1000000-0000-0000-0000-000000000001';

-- Root categories
INSERT INTO catalog_svc.categories (id, tenant_id, catalog_id, parent_id, code, name, sort_order) VALUES
    ('e1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', NULL, 'TYRES',    'Pneumatiques',    1),
    ('e1000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', NULL, 'PARTS',    'Pièces détachées', 2),
    ('e1000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', NULL, 'SERVICES', 'Services',        3);

-- Sub-categories under TYRES
INSERT INTO catalog_svc.categories (id, tenant_id, catalog_id, parent_id, code, name, sort_order) VALUES
    ('e2000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'TYRES_SUMMER',  'Pneus Été',       1),
    ('e2000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'TYRES_WINTER',  'Pneus Hiver',     2),
    ('e2000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'TYRES_ALLSEASON','Pneus 4 Saisons', 3);

-- Sample PRODUCT — tyre
INSERT INTO catalog_svc.products (id, tenant_id, catalog_id, category_id, sku, name, brand, product_type, status, attributes) VALUES
    ('f1000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001',
     'e2000000-0000-0000-0000-000000000001', 'MICH-PS4', 'Michelin Pilot Sport 4', 'MICHELIN', 'PRODUCT', 'ACTIVE',
     '{"season":"summer","vehicle_type":"passenger"}');

-- Variants for Michelin PS4
INSERT INTO catalog_svc.product_variants (id, tenant_id, product_id, sku, name, attributes, sort_order) VALUES
    ('f2000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001',
     'MICH-PS4-205-55R16-91V', '205/55 R16 91V', '{"tire_size":"205/55R16","load_index":"91","speed_rating":"V"}', 1),
    ('f2000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001',
     'MICH-PS4-225-45R17-94Y', '225/45 R17 94Y', '{"tire_size":"225/45R17","load_index":"94","speed_rating":"Y"}', 2);

-- Sample SERVICE — tyre fitting (no variants, priced on product)
INSERT INTO catalog_svc.products (id, tenant_id, catalog_id, category_id, sku, name, product_type, status, base_price, attributes) VALUES
    ('f1000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001',
     'e1000000-0000-0000-0000-000000000003', 'SVC-FITTING', 'Montage pneu', 'SERVICE', 'ACTIVE', 12.00,
     '{"duration_minutes":"30"}');

-- ── Add-on products: services, parts, fees ────────────────────────────────────

-- SERVICE: Wheel balance (labour — mandatory with every tyre)
INSERT INTO catalog_svc.products (id, tenant_id, catalog_id, category_id, sku, name, product_type, status, base_price) VALUES
    ('f1000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001',
     'e1000000-0000-0000-0000-000000000003', 'SVC-WHEEL-BALANCE', 'Équilibrage roue', 'SERVICE', 'ACTIVE', 13.99);

-- PRODUCT: TPMS valve kit (physical part — mandatory with every tyre)
INSERT INTO catalog_svc.products (id, tenant_id, catalog_id, category_id, sku, name, product_type, status, base_price) VALUES
    ('f1000000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001',
     'e1000000-0000-0000-0000-000000000002', 'PART-TPMS-VALVE-KIT', 'Kit valve TPMS', 'PRODUCT', 'ACTIVE', 7.99);

-- SERVICE: TPMS valve kit labour (mandatory — goes with the kit above)
INSERT INTO catalog_svc.products (id, tenant_id, catalog_id, category_id, sku, name, product_type, status, base_price) VALUES
    ('f1000000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001',
     'e1000000-0000-0000-0000-000000000003', 'SVC-TPMS-LABOUR', 'Pose kit valve TPMS', 'SERVICE', 'ACTIVE', 3.31);

-- FEE: Scrap tyre recycling charge (regulatory — mandatory)
INSERT INTO catalog_svc.products (id, tenant_id, catalog_id, category_id, sku, name, product_type, status, base_price, attributes) VALUES
    ('f1000000-0000-0000-0000-000000000006', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001',
     'e1000000-0000-0000-0000-000000000003', 'FEE-TYRE-RECYCLING', 'Taxe recyclage pneu', 'FEE', 'ACTIVE', 4.25,
     '{"fee_type":"regulatory"}');

-- FEE: State environmental fee (regulatory — mandatory)
INSERT INTO catalog_svc.products (id, tenant_id, catalog_id, category_id, sku, name, product_type, status, base_price, attributes) VALUES
    ('f1000000-0000-0000-0000-000000000007', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001',
     'e1000000-0000-0000-0000-000000000003', 'FEE-ENV-STATE', 'Taxe environnementale', 'FEE', 'ACTIVE', 1.00,
     '{"fee_type":"regulatory"}');

-- FEE: Shop supplies (operational — mandatory)
INSERT INTO catalog_svc.products (id, tenant_id, catalog_id, category_id, sku, name, product_type, status, base_price, attributes) VALUES
    ('f1000000-0000-0000-0000-000000000008', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001',
     'e1000000-0000-0000-0000-000000000003', 'FEE-SHOP-SUPPLIES', 'Fournitures atelier', 'FEE', 'ACTIVE', 1.73,
     '{"fee_type":"operational"}');

-- SERVICE: Protection warranty (optional upsell)
INSERT INTO catalog_svc.products (id, tenant_id, catalog_id, category_id, sku, name, product_type, status, base_price, attributes) VALUES
    ('f1000000-0000-0000-0000-000000000009', 'a1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001',
     'e1000000-0000-0000-0000-000000000003', 'SVC-WARRANTY-TYRE', 'Garantie protection pneu (1 an)', 'SERVICE', 'ACTIVE', 9.99,
     '{"duration_months":"12","coverage":"puncture,damage"}');

-- ── Add-on links for Michelin PS4 (tyre package) ──────────────────────────────
-- Maps to Firestone-style "Installation Fees" breakdown:
--   sort 1: Tyre fitting labour            → mandatory
--   sort 2: Wheel balance                  → mandatory
--   sort 3: TPMS Valve Kit (physical part) → mandatory
--   sort 4: TPMS Valve Kit Labour          → mandatory
--   sort 5: Scrap tyre recycling fee       → mandatory (regulatory)
--   sort 6: State environmental fee        → mandatory (regulatory)
--   sort 7: Shop supplies fee              → mandatory (operational)
--   sort 8: Protection warranty            → optional upsell
INSERT INTO catalog_svc.product_addon_links (tenant_id, product_id, addon_id, is_mandatory, default_selected, sort_order) VALUES
    ('a1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000002', true,  false, 1),
    ('a1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000003', true,  false, 2),
    ('a1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000004', true,  false, 3),
    ('a1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000005', true,  false, 4),
    ('a1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000006', true,  false, 5),
    ('a1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000007', true,  false, 6),
    ('a1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000008', true,  false, 7),
    ('a1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000009', false, false, 8);

-- Exclusion example: Lyon store does not offer tyre fitting (no trained staff yet)
INSERT INTO catalog_svc.store_product_exclusions (tenant_id, store_id, product_id, variant_id, reason) VALUES
    ('a1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000003',
     'f1000000-0000-0000-0000-000000000002', NULL, 'Service not yet available at this location');

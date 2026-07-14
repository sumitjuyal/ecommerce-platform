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
--                    store_hours, tenant_users, tenant_user_roles
--
-- Planned services (separate schemas, same pool DB):
--   catalog_svc    → catalogs, categories, products, product_variants  (future)
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
    WHERE schemaname IN ('tenant_svc')
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
    ('a1000000-0000-0000-0000-000000000001', 'u1000000-0000-0000-0000-000000000001', NULL,                                       'TENANT_ADMIN'),
    ('a1000000-0000-0000-0000-000000000001', 'u1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001',    'STORE_MANAGER');

# Catalog Domain — ER Diagram

## Design Rules

| Rule | Implementation |
|---|---|
| One catalog per tenant | `catalogs.tenant_id` unique |
| Categories form a tree | `categories.parent_id` self-reference — unlimited depth |
| Products have a type | `product_type` IN (`PRODUCT`, `SERVICE`, `BUNDLE`) |
| Sellable items are variants | `product_variants` — one row per size/colour/spec combination |
| Services have no variants | `product_type = 'SERVICE'` → price sits on `products.base_price` |
| Default = every product available at every store | No row in `store_product_exclusions` means available |
| Exception-based assortment | `store_product_exclusions` — only the 5% exceptions are stored |
| Exclusion can be product-wide or variant-level | `variant_id NULL` = whole product excluded; set = specific variant only |
| Flexible attributes via jsonb + normalised rows | `products.attributes` for the bag; `product_attributes` for searchable key/value |

---

## ER Diagram

```mermaid
erDiagram

  CATALOGS          ||--o{ CATEGORIES             : "contains"
  CATEGORIES        ||--o{ CATEGORIES             : "parent-child"
  CATALOGS          ||--o{ PRODUCTS               : "lists"
  CATEGORIES        ||--o{ PRODUCTS               : "groups"
  PRODUCTS          ||--o{ PRODUCT_VARIANTS        : "has variants"
  PRODUCTS          ||--o{ PRODUCT_ATTRIBUTES      : "described by"
  PRODUCT_VARIANTS  ||--o{ PRODUCT_ATTRIBUTES      : "described by"
  PRODUCTS          ||--o{ STORE_PRODUCT_EXCLUSIONS: "excluded from"
  PRODUCT_VARIANTS  ||--o{ STORE_PRODUCT_EXCLUSIONS: "variant excluded from"

  CATALOGS {
    uuid        id PK
    uuid        tenant_id             "unique — one catalog per tenant"
    varchar     name
    varchar     default_locale        "e.g. fr-FR"
    char        currency_code         "e.g. EUR"
    varchar     status                "ACTIVE | ARCHIVED"
    timestamptz created_at
    timestamptz updated_at
  }

  CATEGORIES {
    uuid        id PK
    uuid        tenant_id             "denormalised"
    uuid        catalog_id FK
    uuid        parent_id FK          "NULL = root category"
    varchar     code                  "e.g. TYRES, TYRES_SUMMER"
    varchar     name                  "e.g. Pneumatiques"
    text        description
    varchar     image_url
    int         sort_order
    boolean     is_active
    timestamptz created_at
    timestamptz updated_at
  }

  PRODUCTS {
    uuid        id PK
    uuid        tenant_id             "denormalised"
    uuid        catalog_id FK
    uuid        category_id FK
    varchar     sku                   "master SKU"
    varchar     name
    text        description
    varchar     brand
    varchar     product_type          "PRODUCT | SERVICE | BUNDLE"
    varchar     status                "DRAFT | ACTIVE | DISCONTINUED"
    numeric     base_price            "used for SERVICE type (no variants)"
    jsonb       attributes            "flexible bag: season, vehicle_type, etc."
    varchar     image_url
    timestamptz created_at
    timestamptz updated_at
  }

  PRODUCT_VARIANTS {
    uuid        id PK
    uuid        tenant_id             "denormalised"
    uuid        product_id FK
    varchar     sku                   "e.g. MICH-PS4-205-55R16-91V"
    varchar     name                  "e.g. 205/55 R16 91V"
    jsonb       attributes            "tire_size, load_index, speed_rating"
    varchar     status                "ACTIVE | DISCONTINUED"
    int         sort_order
    timestamptz created_at
    timestamptz updated_at
  }

  PRODUCT_ATTRIBUTES {
    uuid        id PK
    uuid        tenant_id             "denormalised"
    uuid        product_id FK
    uuid        variant_id FK         "NULL = product-level attribute"
    varchar     key                   "e.g. tire_size"
    varchar     value                 "e.g. 205/55R16"
    timestamptz created_at
  }

  STORE_PRODUCT_EXCLUSIONS {
    uuid        id PK
    uuid        tenant_id             "denormalised"
    uuid        store_id              "logical → tenant_svc.stores.id"
    uuid        product_id FK
    uuid        variant_id FK         "NULL = all variants excluded"
    varchar     reason                "e.g. Not stocked at this location"
    timestamptz excluded_at
    uuid        excluded_by           "logical → tenant_svc.tenant_users.id"
  }
```

---

## Key Design Decisions

### Exception-based assortment
Most assortment models use an opt-in table (a row per store-product pair = millions of rows). For Speedy France where 95% of products are available everywhere, we invert this:

> **No row = available. A row = excluded.**

Query to check if a product is available at a store:
```sql
SELECT COUNT(*) = 0 AS is_available
FROM catalog_svc.store_product_exclusions
WHERE store_id  = $1
  AND product_id = $2
  AND (variant_id IS NULL OR variant_id = $3);
```

Query to get all available products at a store:
```sql
SELECT p.*
FROM catalog_svc.products p
WHERE p.catalog_id = $1
  AND p.status = 'ACTIVE'
  AND p.id NOT IN (
    SELECT product_id FROM catalog_svc.store_product_exclusions
    WHERE store_id = $2 AND variant_id IS NULL
  );
```

### `PRODUCT` vs `SERVICE` type
- `PRODUCT` — has variants (e.g. a tyre in different sizes); price is on the variant via pricing_svc
- `SERVICE` — no variants (e.g. tyre fitting); `base_price` sits directly on the product row
- `BUNDLE` — reserved for future grouped offerings (e.g. tyre + fitting package)

### Category tree depth
`parent_id` self-reference supports unlimited nesting:
```
TYRES (root)
 └── TYRES_SUMMER
 └── TYRES_WINTER
 └── TYRES_ALLSEASON
SERVICES (root)
PARTS (root)
```
Application layer uses recursive CTE to fetch full subtree when needed.

### `attributes` jsonb + `product_attributes` rows
Two complementary approaches:
- `products.attributes` jsonb — fast reads, no schema change needed for new attributes
- `product_attributes` rows — normalised, indexable on `(key, value)` for filtered search (e.g. "find all 205/55R16 tyres")

---

## Cross-Domain References (logical — no FK constraints across services)

| Column | Points To | Owned By |
|---|---|---|
| `catalogs.tenant_id` | `tenant_svc.tenants.id` | Tenant service |
| `store_product_exclusions.store_id` | `tenant_svc.stores.id` | Tenant service |
| `store_product_exclusions.excluded_by` | `tenant_svc.tenant_users.id` | Tenant service |

---

## Catalog Service API Surface (planned)

| Operation | Notes |
|---|---|
| `GET /catalogs/{tenantId}/products` | List all active products for a tenant |
| `GET /catalogs/{tenantId}/products?storeId=` | List products available at a specific store (applies exclusions) |
| `GET /catalogs/{tenantId}/categories` | Full category tree |
| `GET /products/{id}/variants` | All variants for a product |
| `POST /catalogs/{tenantId}/exclusions` | Exclude a product from a store |
| `DELETE /catalogs/{tenantId}/exclusions/{id}` | Re-include a previously excluded product |

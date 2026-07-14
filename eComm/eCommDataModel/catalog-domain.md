# Catalog Domain — ER Diagram

## Design Rules

| Rule | Implementation |
|---|---|
| One catalog per tenant | `catalogs.tenant_id` unique |
| Categories form a tree | `categories.parent_id` self-reference — unlimited depth |
| Products have a type | `product_type` IN (`PRODUCT`, `SERVICE`, `BUNDLE`) |
| Sellable items are variants | `product_variants` — one row per size/colour/spec combination |
| Single-SKU product still has one variant | Keeps pricing and inventory anchored to `variant_id` consistently |
| Services have no variants | `product_type = 'SERVICE'` → price on `products.base_price` |
| Products can have mandatory and optional services | `product_service_links` — e.g. tyre → fitting (mandatory) + warranty (optional) |
| Default = every product available at every store | No row in `store_product_exclusions` means available |
| Exception-based assortment | `store_product_exclusions` — only the 5% exceptions are stored |
| Exclusion can be product-wide or variant-level | `variant_id NULL` = whole product excluded; set = specific variant only |
| Flexible attributes via jsonb + normalised rows | `products.attributes` for the bag; `product_attributes` for searchable key/value |

---

## Product Types Explained

### PRODUCT
A physical item sold by SKU (e.g. Michelin Pilot Sport 4).
- Has one or more **variants** (e.g. 205/55R16, 225/45R17)
- Price is set at the variant level in `pricing_svc`
- **Single-SKU product:** still creates one variant row — keeps pricing/inventory logic uniform

### SERVICE
A standalone service that can be sold independently or linked to a product.
- **No variants** — nothing to vary
- Price sits directly on `products.base_price` (or can be overridden in `pricing_svc`)
- Examples: tyre fitting, wheel alignment, nitrogen inflation, protection warranty

### BUNDLE
A **fixed pre-packaged** offering sold as a single unit with one SKU and one bundle price.
- The bundle has its own product row and its own price
- Components are defined in `bundle_items` (future table — not yet implemented)
- Example: "Pack Hiver" = 4 winter tyres + fitting + tyre storage, sold at a fixed package price

> **Bundle vs Product-Service Association:**
> A bundle has ONE price for the whole package. A product-service association prices each component independently. If a customer buys a tyre and the fitting cost shows separately on the invoice → that is a **product-service link**. If the whole pack is one line item → that is a **bundle**.

---

## Product-Service Association (mandatory + optional services)

When a PRODUCT requires or offers related SERVICEs, `product_service_links` defines the relationship.

| `is_mandatory` | `default_selected` | Behaviour |
|---|---|---|
| `true` | `false` | Auto-added to cart, customer cannot remove it |
| `false` | `true` | Pre-ticked in UI, customer can opt out |
| `false` | `false` | Shown as an upsell, customer must opt in |

**Speedy France example — buying a tyre:**
```
Michelin PS4 (PRODUCT)
  ├── Tyre Fitting — SVC-FITTING         is_mandatory=true   (auto-added, no choice)
  └── Protection Warranty — SVC-WARRANTY is_mandatory=false  (upsell, opt-in)
```

Cart total = tyre price + fitting price + (warranty price if selected)

---

## ER Diagram

```mermaid
erDiagram

  CATALOGS          ||--o{ CATEGORIES              : "contains"
  CATEGORIES        ||--o{ CATEGORIES              : "parent-child"
  CATALOGS          ||--o{ PRODUCTS                : "lists"
  CATEGORIES        ||--o{ PRODUCTS                : "groups"
  PRODUCTS          ||--o{ PRODUCT_VARIANTS         : "has variants"
  PRODUCTS          ||--o{ PRODUCT_ATTRIBUTES       : "described by"
  PRODUCT_VARIANTS  ||--o{ PRODUCT_ATTRIBUTES       : "described by"
  PRODUCTS          ||--o{ PRODUCT_SERVICE_LINKS    : "linked services (as product)"
  PRODUCTS          ||--o{ PRODUCT_SERVICE_LINKS    : "linked to products (as service)"
  PRODUCTS          ||--o{ STORE_PRODUCT_EXCLUSIONS : "excluded from"
  PRODUCT_VARIANTS  ||--o{ STORE_PRODUCT_EXCLUSIONS : "variant excluded from"

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
    numeric     base_price            "SERVICE type only — no variants"
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

  PRODUCT_SERVICE_LINKS {
    uuid        id PK
    uuid        tenant_id             "denormalised"
    uuid        product_id FK         "the PRODUCT being purchased"
    uuid        service_id FK         "the SERVICE being linked (must be SERVICE type)"
    boolean     is_mandatory          "true = auto-added, cannot be removed"
    boolean     default_selected      "true = pre-ticked for optional services"
    int         sort_order            "UI display order"
    timestamptz created_at
    timestamptz updated_at
  }

  STORE_PRODUCT_EXCLUSIONS {
    uuid        id PK
    uuid        tenant_id             "denormalised"
    uuid        store_id              "logical → tenant_svc.stores.id"
    uuid        product_id FK
    uuid        variant_id FK         "NULL = all variants excluded"
    varchar     reason
    timestamptz excluded_at
    uuid        excluded_by           "logical → tenant_svc.tenant_users.id"
  }
```

---

## Key Design Decisions

### Single-SKU products still have one variant
Pricing and inventory always anchor to `variant_id`, never `product_id`. This means the checkout and pricing services have one consistent code path regardless of how many variants a product has. A "single-SKU" product is just a product with one variant row.

### Exception-based assortment
Most assortment models use an opt-in table (a row per store-product pair = millions of rows). For Speedy France where 95% of products are available everywhere, we invert:

> **No row = available. A row = excluded.**

Query to check if a product is available at a store:
```sql
SELECT COUNT(*) = 0 AS is_available
FROM catalog_svc.store_product_exclusions
WHERE store_id   = $1
  AND product_id = $2
  AND (variant_id IS NULL OR variant_id = $3);
```

### `attributes` jsonb + `product_attributes` rows
Two complementary approaches:
- `products.attributes` jsonb — fast reads, no schema change for new attributes
- `product_attributes` rows — normalised, indexed on `(key, value)` for filtered search (e.g. "find all 205/55R16 tyres")

### Category tree depth
`parent_id` self-reference supports unlimited nesting. Application layer uses a recursive CTE to fetch subtrees:
```sql
WITH RECURSIVE tree AS (
  SELECT * FROM catalog_svc.categories WHERE parent_id IS NULL AND catalog_id = $1
  UNION ALL
  SELECT c.* FROM catalog_svc.categories c JOIN tree t ON c.parent_id = t.id
)
SELECT * FROM tree;
```

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
| `GET /catalogs/{tenantId}/products` | List all active products |
| `GET /catalogs/{tenantId}/products?storeId=` | Apply store exclusions filter |
| `GET /catalogs/{tenantId}/categories` | Full category tree |
| `GET /products/{id}/variants` | All variants for a product |
| `GET /products/{id}/services` | Mandatory + optional services linked to a product |
| `POST /catalogs/{tenantId}/exclusions` | Exclude a product from a store |
| `DELETE /catalogs/{tenantId}/exclusions/{id}` | Re-include a previously excluded product |

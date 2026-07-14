# Catalog Domain — ER Diagram

## Design Rules

| Rule | Implementation |
|---|---|
| One catalog per tenant | `catalogs.tenant_id` unique |
| Categories form a tree | `categories.parent_id` self-reference — unlimited depth |
| Products have a type | `product_type` IN (`TIRE`, `PART`, `LABOR`, `FEE`, `BUNDLE`) |
| Sellable items are variants | `product_variants` — one row per size/colour/spec combination |
| Single-SKU product still has one variant | Keeps pricing and inventory anchored to `variant_id` consistently |
| LABOR and FEE have no variants | Price on `products.base_price` — nothing to vary |
| Product-type add-ons apply to all products sharing the same type | `product_type_addon_links` — define once for `TIRE`, inherited by every tyre regardless of category |
| Product-level add-ons override type defaults | `product_addon_links` — used only for exceptions, most products have no rows here |
| FEE = regulatory charge only | Must appear as separate invoice line by law — recycling tax, env fee |
| Default = every product available at every store | No row in `store_product_exclusions` means available |
| Exception-based assortment | `store_product_exclusions` — only the 5% exceptions are stored |
| Exclusion can be product-wide or variant-level | `variant_id NULL` = whole product excluded; set = specific variant only |
| Flexible attributes via jsonb + normalised rows | `products.attributes` for the bag; `product_attributes` for searchable key/value |

---

## Product Types Explained

### TIRE
A physical tyre sold by SKU (e.g. Bridgestone Turanza T005, Bridgestone Blizzak WS90).
- Has one or more **variants** (e.g. 205/55R16, 225/45R17)
- Price is set at the variant level in `pricing_svc`
- **Single-SKU tyre:** still creates one variant row — keeps pricing/inventory logic uniform
- Automatically inherits add-ons (installation, fees, warranty) via `product_type_addon_links`

### PART
A physical accessory or replacement part (e.g. TPMS Valve Kit, wheel bolt set).
- Has variants when multiple sizes/specs exist
- Price at the variant level in `pricing_svc`
- Can be linked as a mandatory or optional add-on to a TIRE via `product_addon_links`

### LABOR
A labour or service item — no physical inventory (e.g. tyre installation, protection warranty).
- **No variants** — nothing to vary
- Price on `products.base_price`
- Linked as a mandatory or optional add-on via `product_type_addon_links`

### FEE
A regulatory charge that must appear as a **separate line on the invoice** — required by law, customer cannot remove.
- **No variants, no inventory**
- Price on `products.base_price`
- Examples: Scrap Tyre Recycling Charge, State Environmental Fee
- `attributes.fee_type` = `'regulatory'` — drives invoice rendering and tax treatment

### BUNDLE
A **fixed pre-packaged** offering sold as a single unit with one SKU and one bundle price.
- Components are defined in `bundle_items` (future table — not yet implemented)
- Example: Winter Pack = 4 winter tyres + fitting + storage at one fixed price

> **Bundle vs Add-on Links:**
> If each component has a separate line on the invoice → use `product_addon_links`.
> If the whole pack is one line item at one price → use `BUNDLE`.

---

## Real-World Example — Tyre Package

**What the customer sees (invoice):**

```
Bridgestone Turanza T005 205/55R16 91V  × 4   €823.96   ← TIRE + variant, price from pricing_svc
Tyre Installation Package              × 4   €180.00   ← LABOR  SVC-TYRE-INSTALL €45.00 each
Tyre Recycling Fee            × 4   € 17.00   ← FEE      regulatory, separate line by law
State Environmental Fee       × 4   €  4.00   ← FEE      regulatory, separate line by law
──────────────────────────────────────────────
Subtotal                           €1,024.96
Taxes                              €   56.95
Out the door                       €1,081.91

Optional: Tyre Protection Warranty × 4  €39.96  ← SERVICE opt-in upsell
```

**How add-ons are linked (product_type_addon_links on type TIRE):**

```
product_type = TIRE
  └── SVC-TYRE-INSTALL    is_mandatory=true   sort=1  (every tyre sold includes install)
  └── FEE-TYRE-RECYCLING  is_mandatory=true   sort=2  (law requires separate line)
  └── FEE-ENV-STATE       is_mandatory=true   sort=3  (law requires separate line)
  └── SVC-WARRANTY-TYRE   is_mandatory=false  sort=4  (optional upsell)
```

Applies automatically to Bridgestone Turanza T005, Michelin Pilot Sport 4, Toyo PROXES — every tyre, regardless of category.

---

## Add-on Inheritance — Product Type → Product

Add-ons are defined at the **product type level** and inherited by every product sharing that type. Category membership is irrelevant — a tyre added directly to the catalog without any category still inherits its add-ons.

```
product_type = TIRE  ← product_type_addon_links defined here once
  ├── Bridgestone Turanza T005 → inherits all add-ons automatically
  ├── Michelin Pilot Sport 4  → inherits all add-ons automatically
  ├── Toyo PROXES             → inherits all add-ons automatically
  └── Run-flat XYZ            → inherits type defaults + product_addon_links override (e.g. no installation)
```

**Checkout resolution order:**
1. Load `product_type_addon_links` for the product's `product_type`
2. Merge `product_addon_links` for the specific product
3. Product-level entry wins when the same `addon_id` appears in both

**Add-on behaviour:**

| `is_mandatory` | `default_selected` | Behaviour |
|---|---|---|
| `true` | — | Auto-added to cart, customer cannot remove |
| `false` | `true` | Pre-ticked in UI, customer can opt out |
| `false` | `false` | Shown as upsell, customer must opt in |

---

## ER Diagram

```mermaid
erDiagram

  CATALOGS                  ||--o{ CATEGORIES                  : "contains"
  CATEGORIES                ||--o{ CATEGORIES                  : "parent-child"
  CATALOGS                  ||--o{ PRODUCTS                    : "lists"
  CATEGORIES                ||--o{ PRODUCTS                    : "groups (navigation only)"
  PRODUCTS                  ||--o{ PRODUCT_VARIANTS            : "has variants"
  PRODUCTS                  ||--o{ PRODUCT_ATTRIBUTES          : "described by"
  PRODUCT_VARIANTS          ||--o{ PRODUCT_ATTRIBUTES          : "described by"
  PRODUCT_TYPE_ADDON_LINKS  }o--|| PRODUCTS                    : "addon_id references"
  PRODUCTS                  ||--o{ PRODUCT_ADDON_LINKS         : "product-level override (as parent)"
  PRODUCTS                  ||--o{ PRODUCT_ADDON_LINKS         : "is override add-on (as addon)"
  PRODUCTS                  ||--o{ STORE_PRODUCT_EXCLUSIONS    : "excluded from"
  PRODUCT_VARIANTS          ||--o{ STORE_PRODUCT_EXCLUSIONS    : "variant excluded from"

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
    uuid        category_id FK        "NULL = no category — addons still work via product_type"
    varchar     sku                   "master SKU"
    varchar     name
    text        description
    varchar     brand
    varchar     product_type          "TIRE | PART | LABOR | FEE | BUNDLE"
    varchar     status                "DRAFT | ACTIVE | DISCONTINUED"
    numeric     base_price            "LABOR and FEE types — no variants"
    jsonb       attributes            "flexible bag: season, vehicle_type, fee_type, etc."
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

  PRODUCT_TYPE_ADDON_LINKS {
    uuid        id PK
    uuid        tenant_id             "denormalised"
    varchar     product_type          "TIRE | PART | LABOR | FEE | BUNDLE"
    uuid        addon_id FK           "LABOR or FEE product"
    boolean     is_mandatory          "true = auto-added, cannot be removed"
    boolean     default_selected      "true = pre-ticked for optional add-ons"
    int         sort_order            "UI display order"
    timestamptz created_at
    timestamptz updated_at
  }

  PRODUCT_ADDON_LINKS {
    uuid        id PK
    uuid        tenant_id             "denormalised"
    uuid        product_id FK         "specific product override"
    uuid        addon_id FK           "SERVICE, PRODUCT (part), or FEE"
    boolean     is_mandatory          "overrides category-level value"
    boolean     default_selected
    int         sort_order
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
| `GET /products/{id}/addons` | All add-ons linked to a product (services, parts, fees) — mandatory and optional |
| `POST /catalogs/{tenantId}/exclusions` | Exclude a product from a store |
| `DELETE /catalogs/{tenantId}/exclusions/{id}` | Re-include a previously excluded product |

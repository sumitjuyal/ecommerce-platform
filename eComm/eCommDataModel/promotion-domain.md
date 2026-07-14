# Promotion Domain — ER Diagram

## Design Rules

| Rule | Implementation |
|---|---|
| One promotion definition per `code` | `promotions.code` unique |
| Tenant scope: `ALL` or specific tenant | `promotions.tenant_id` — default `'ALL'` means any tenant |
| Store scope: `ALL` or specific store | `promotions.store_number` — default `'ALL'` means any store |
| Coupon-gated promotions | `requires_coupon = true` + `required_coupon_code` |
| SKU / category allow-lists and block-lists | `included_skus`, `excluded_skus`, `included_categories`, `excluded_categories` (comma-separated) |
| Drools agenda groups control evaluation order | `agenda_group` = `'order'` or `'item'`; `salience` controls priority within a group |
| Every redemption is audited | `promotion_redemptions` row written per order per promotion applied |
| Config entries are reference data for the UI | `config_entries` drives dropdowns: tenants, stores, categories, order conditions |

---

## ER Diagram

```mermaid
erDiagram

  PROMOTIONS ||--o{ PROMOTION_REDEMPTIONS : "redeemed via"
  CONFIG_ENTRIES }o--|| PROMOTIONS         : "configures (reference)"

  PROMOTIONS {
    bigint      id PK
    varchar     code              "unique promotion code"
    varchar     name
    text        description
    varchar     type              "ORDER_DISCOUNT | ITEM_DISCOUNT"
    text        parameters        "JSON: discountType, condition, threshold, percentage, amount"
    varchar     agenda_group      "Drools group: order | item"
    int         salience          "Drools priority within group"
    boolean     stackable
    varchar     tenant_id         "ALL or specific tenant slug"
    varchar     store_number      "ALL or specific store code"
    boolean     requires_coupon
    varchar     required_coupon_code
    varchar     included_categories "comma-separated whitelist"
    varchar     excluded_categories "comma-separated blacklist"
    varchar     included_skus
    varchar     excluded_skus
    boolean     enabled
    timestamptz created_at
    timestamptz updated_at
  }

  CONFIG_ENTRIES {
    bigint      id PK
    varchar     config_type       "TENANT | STORE | CATEGORY | ORDER_CONDITION"
    varchar     entry_value       "the actual DRL value or code"
    varchar     label             "human-readable display"
    text        description
    boolean     requires_input    "true = user must supply a threshold value"
    int         sort_order
    boolean     enabled
  }

  PROMOTION_REDEMPTIONS {
    uuid        id PK
    bigint      promotion_id FK
    uuid        order_id          "logical → order_svc.orders.id"
    uuid        customer_id       "logical → customer_svc.customers.id; NULL = guest"
    varchar     tenant_id
    varchar     store_number
    numeric     discount_amount
    varchar     coupon_code
    timestamptz redeemed_at
  }
```

---

## Key Design Decisions

### `parameters` column is a JSON blob
The promotion engine uses Drools DRL templates that read `parameters` at rule-compile time. Keeping it as `TEXT` (JSON) avoids schema migrations every time a new discount strategy is added. The UI form controls which keys are relevant per `type`.

### Drools pipeline: agenda groups + salience
- `agenda_group = 'order'` → evaluated against the whole cart (`totalAmount`, `totalItemCount`, customer flags)
- `agenda_group = 'item'` → evaluated per `CartItem` (`category`, `sku`)
- Higher `salience` fires first within a group; non-stackable promotions cancel lower-priority ones

### `tenant_id = 'ALL'` and `store_number = 'ALL'`
National promotions use `'ALL'` as a wildcard. The Drools filter checks `(promo.tenantId == 'ALL' || promo.tenantId == cart.tenantId)` and likewise for store. This means a Speedy-specific promo (`tenant_id = 'SPEEDY_FR'`) never fires for a different tenant.

### Redemption audit trail
`promotion_redemptions` is append-only. It enables:
- Per-customer redemption counts (coupon-once-per-customer logic)
- Revenue-impact reporting per promotion
- Rollback: cancelling an order can zero out redemption records

---

## Microservice Boundary

| Service | Tables |
|---|---|
| **Promotion service** | `promotions`, `config_entries`, `promotion_redemptions` |

Cross-service references (logical — no DB-level FK constraints):

| Column | Points To | Owned By |
|---|---|---|
| `promotion_redemptions.order_id` | `order_svc.orders.id` | Order service |
| `promotion_redemptions.customer_id` | `customer_svc.customers.id` | Customer service |

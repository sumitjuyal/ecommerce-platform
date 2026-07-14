# Backlog — Deferred Design Decisions

Items parked during design sessions. Revisit before implementing the affected service.

---

## Catalog Domain

### Variable Labor (time-based pricing)
**Parked during:** UOM design session
**Context:** Two types of labor exist — fixed price (modelled) and variable (time × rate).
Variable labor: technician logs hours against a job; invoice = `hours_logged × rate_per_hour`.
Every technician bills the same rate (no seniority tiers).
**What needs designing:**
- Where does `rate_per_hour` live — on the article (`base_price` repurposed) or a separate column?
- Is `hours_logged` captured at order time, or after job completion?
- Is there a `standard_hours` estimate on the article for quoting upfront?
- `uom` for variable labor = `HOUR` — already in the CHECK constraint, ready to use
**Depends on:** Order domain (where job time gets recorded)

---

### Oil and Volume-Based UOM
**Parked during:** UOM design session — stepped through TIRE/PART/LABOR first
**Context:** Oil articles (e.g. 5W-30 Engine Oil) sell by volume — LITER or QUART.
Oil change labor can be priced per quart (variable qty driven by oil volume selected).
**What needs designing:**
- One SKU with UOM conversion (1L / 5L at the same base rate), or separate SKUs per pack size?
- Is oil-change labor qty truly variable (= oil qty), or always a flat JOB price?
- `uom` values LITER and QUART already in the CHECK constraint, ready to use
- If UOM conversion: needs a `uom_conversion` table (from_uom, to_uom, factor)
**Depends on:** Pricing domain (how price-per-unit is stored for volume articles)

---

### BUNDLE — bundle_items table
**Parked during:** Initial catalog design
**Context:** BUNDLE product type is defined and seeded but `bundle_items` table is not yet implemented.
**What needs designing:**
- `bundle_items (bundle_id, product_id, variant_id, qty)` — components of the bundle
- Bundle price is fixed on `products.base_price` — component prices are ignored at checkout
- Inventory deduction: reduce stock per component variant when bundle is sold
**Depends on:** Order domain, inventory service

---

### Wheel Alignment / Tyre Rotation as catalog articles
**Parked during:** UOM design session
**Context:** Confirmed these are JOB/PER_JOB articles — flat charge once per visit regardless of tyre qty.
Not yet seeded. Ready to add when services catalog is built out.
**Articles to add:** `SVC-WHEEL-ALIGN` (JOB), `SVC-TYRE-ROTATION` (JOB)

---

## Pricing Domain

*(populated as pricing design sessions progress)*

---

## Order Domain

### Tax Design
**Parked during:** Order domain design session
**Context:** Tax placeholder columns (`tax_amount`) exist on `cart_lines` and `order_lines`. No calculation logic designed yet.
**What needs designing:**
- Tax rule source — flat rate per tenant/store, or rule engine (product type × jurisdiction)?
- VAT vs. sales tax handling for multi-country expansion
- Tax-inclusive vs. tax-exclusive pricing display
- Whether tax is stored as a rate or an amount on the line
**Depends on:** Pricing domain (is tax part of the displayed price?)

---

### Promotion Engine — Job Hierarchy
**Parked during:** Order domain design session
**Context:** Current engine (`Cart.java`) takes a flat `List<CartItem>`. Order domain is designed around `Cart → List<Job> → List<CartItem>`. The engine needs to evolve to support job-level promotions.
**What needs doing:**
- Add `Job` wrapper model to `Cart.java`: `List<Job> jobs` where `Job { jobId, packageId, couponCode, List<CartItem> items }`
- Add a third Drools agenda group `"job"` between `"item"` and `"order"`
- Job discount must be spread proportionally across lines in the job (same approach as order discount)
- `cart_jobs.coupon_code` and `order_jobs.coupon_code` columns are already present in the schema — no DDL change needed
**Depends on:** Promotion engine project (`promotion-engine/src/main/java/.../model/`)

---

### Package Service Design
**Parked during:** Order domain design session
**Context:** `cart_jobs.package_id` references a future `package_svc`. A package is a pre-defined grouping of articles (TIRE + LABOR + FEE) that the cart resolves into job lines.
**What needs designing:**
- `packages` table: `(id, tenant_id, name, product_type_target)`
- `package_items` table: `(package_id, product_id, variant_id, qty, is_mandatory)` — the articles that make up the package
- How packages interact with `product_type_addon_links` — does the package override addon resolution, or supplement it?
- Store-level package exclusions
**Depends on:** Catalog domain (packages reference catalog articles)

---

### Appointment Service Design
**Parked during:** Order domain design session
**Context:** `cart_jobs.appointment_id` and `order_jobs.appointment_id` are logical references to a future `appointment_svc`. Two jobs in one order can share the same appointment ID (same visit).
**What needs designing:**
- Appointment booking flow — created before or after cart checkout?
- Slot availability model (store capacity, technician assignment)
- Appointment cancellation cascade when order is cancelled
- Time zone handling per store
**Depends on:** Order domain (appointment linked at job level)

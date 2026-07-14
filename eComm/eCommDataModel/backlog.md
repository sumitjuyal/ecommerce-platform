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

*(populated as order design sessions progress)*

# OrionORM v0.6.0 — Release Notes

**Date:** 2025-08-16

> TL;DR: safer SQL, smarter indexes, better types & performance, new telemetry hook, and sturdier pooling. A few breaking changes — see the Upgrade Checklist.

---

## ✨ Highlights

### 1) Index management (unique / non-unique / composite)

* Define indexes (including **composite** and **prefix lengths**) directly on models.
* Created **idempotently** using `information_schema`, with deterministic names (e.g. `uq_users_email`, `idx_posts_user_id_created_at`).
* Applied during `migrate!`, together with FK creation.

### 2) Safer `include`: no unused JOINs

* Removed internal `JOIN`s that were not being consumed by the result assembler.
* Keeps **eager loading via subqueries** (chunked `IN` batches) — less duplication, smaller result sets, predictable memory use.

### 3) Stronger types & nullability

* SQL helpers (`TEXT()`, `INTEGER()`, `DOUBLE()`, `FLOAT()`, `UUID()`, `DATE()`, `TIMESTAMP()`, `JSON()`) now return **plain `String`**.
* Columns without `NOT NULL` map to **`Union{T,Missing}`**. No more sentinel values like `0`, `""`, or `Date(0)`.

### 4) QueryBuilder robustness

* Empty sets are now well-defined:

  * `IN []` ⇒ generates `1=0` (matches nothing).
  * `NOT IN []` ⇒ generates `1=1` (matches everything).
* Consistent **identifier quoting** with backticks for tables/columns.

### 5) Validation

* Early **model/table validation** before building SQL, with clear errors if a name is invalid or not registered.

### 6) Telemetry hook

* `onQueryHook` now carries `(sql, params, meta)` where `meta = (isSelect::Bool, useTransaction::Bool)`.
* Easy to plug counters, timings, and redaction.

### 7) Pool watchdog hardening

* Watchdog **does not close in-use connections** anymore. Instead, it marks them **stale** and **recycles on release**, avoiding native client crashes on “stale” handles.
* Added internal **generation** tracking for safer recycling.

### 8) New throwing helpers

* `findFirstOrThrow(...)`
* `findUniqueOrThrow(model, uniqueField, value)`

Both raise `RecordNotFoundError` when there’s no match.

---

## ⚠️ Breaking changes

* **Nullability:** fields for nullable columns are now `Union{T,Missing}`. Callers must handle `missing`.
* **Include path:** removal of internal JOINs can change row shapes/performance characteristics (returned data is the same, but produced without duplicated rows).
* **Stricter validation:** invalid table/column names fail fast with explicit errors (previously could pass through to SQL).

---

## 🧭 Upgrade checklist

1. **Handle `missing`:**

   * Review places that assumed sentinels (`0`, `""`, `Date(0)`) and update to check for `ismissing(x)`.
2. **Includes:**

   * If you post-processed JOIN-generated duplicates, remove that logic; eager subqueries already return clean parent/children.
3. **Validation:**

   * Ensure all queried models/columns exist in your registered models; fix typos revealed by new checks.
4. **Telemetry (optional):**

   * Attach a hook (see snippet below) to start collecting timings and errors.
5. **Indexes (optional but recommended):**

   * Declare composite/unique indexes on hot paths to unlock the migration automation.

---

## 📌 Examples

### Define composite & unique indexes

```julia
Model(:users, [
  ("id", INTEGER(), [PrimaryKey(), AutoIncrement(), NotNull()]),
  ("email", VARCHAR(255), [NotNull(), Unique()]),
  ("created_at", TIMESTAMP(), [Default("CURRENT_TIMESTAMP")]),
], [], [
  # unique by default via Unique() on column; extra example:
  Dict("name"=>"uq_users_email", "columns"=>["email"], "unique"=>true),
])

Model(:posts, [
  ("id", INTEGER(), [PrimaryKey(), AutoIncrement(), NotNull()]),
  ("user_id", INTEGER(), [NotNull()]),
  ("created_at", TIMESTAMP(), [Default("CURRENT_TIMESTAMP")]),
], [
  # belongsTo(user)
  (:user_id, :users, "id", :belongsTo),
], [
  Dict("name"=>"idx_posts_user_created", "columns"=>["user_id","created_at"], "unique"=>false)
])
```

### Empty set semantics

```julia
# IN []
findMany(User; query=Dict("where"=>Dict("id"=>Dict("in"=>Int[]))))   # → 1=0 (no rows)

# NOT IN []
findMany(User; query=Dict("where"=>Dict("id"=>Dict("notIn"=>Int[])))) # → 1=1 (all rows)
```

### Throwing helpers

```julia
user = findFirstOrThrow(User; query=Dict("where"=>Dict("id"=>123)))
post = findUniqueOrThrow(Post, "slug", "hello-world")
```

---

## 🧪 Stability & performance notes

* Eager loading keeps **chunked `IN` batches** to prevent oversized statements.
* Automatic index creation during migrations improves `WHERE`/FK lookups without manual DDL.
* Pool watchdog changes prevent “stale handle” native crashes while keeping auto-healing behavior.


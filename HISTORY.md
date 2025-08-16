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


# OrionORM v0.5.0 Release Notes

I’m thrilled to announce the v0.5.0 release of OrionORM! This milestone brings a ground-up overhaul of our query builder, connection management, bulk-operation support, and a vastly expanded test suite. 

---

## 🚀 Highlights

### 1. QueryBuilder v2 with Prepared Statements

* Full support for **nested filters** (`AND`, `OR`, `not`)
* Array operations: **`in`**, **`notIn`**
* Pattern matching: **`contains`**, **`startsWith`**, **`endsWith`**
* Automatic **LEFT JOIN** when using `include=[Model]`, so parents without children still appear
* Uniform builders:

  * `buildSelectQuery` → `(sql, params)` for SELECT
  * `buildInsertQuery`, `buildUpdateQuery`, `buildDeleteQuery` for the respective CRUD

### 2. Unified `executeQuery` API

* **High-level**: `executeQuery(sql, params; useTransaction=true)` opens and closes a connection automatically
* **Low-level**: `executeQuery(conn, sql, params; useTransaction=true)` reuses your own connection (ideal for multi-statement transactions)
* Auto-detects:

  * **SELECT** → returns `DataFrame`
  * **INSERT/UPDATE/DELETE** → returns number of affected rows (`Int`)
  * **DDL** (CREATE/DROP/ALTER) → returns `Bool` on success
* Always closes prepared statements to prevent “commands out of sync”

### 3. Bulk Operations

* Chunked, transactional bulk inserts:

  * `buildBatchInsertQuery(model, records)`
  * `createMany(model, records; chunkSize, transaction=true)`
  * `createManyAndReturn(model, records)`
* New `updateManyAndReturn(model, query, data)` to fetch only the updated rows

### 4. Enhanced `findMany` & `findFirst`

* `include=[Model]` now yields a `Vector{Dict{String,Any}}` pairing each parent with its children array—empty if none
* Internally uses a single LEFT JOIN and efficient post-processing into your struct instances

### 5. Connection Pool Improvements

* Robust connection **validation**, **auto-reconnect**, and **safe release**
* Explicit support for **long-lived transactions** without leaking pool slots

### 6. Expanded Test Suite

* **Negative and edge-case tests** for:

  * Missing `where` clauses, invalid operators, and `findUniqueOrThrow` failure paths
  * All QueryBuilder operators, including complex nested filters
  * `include` edge cases (parents with zero children)
  * Default timestamp behavior for `TIMESTAMP` columns
  * Transaction rollback semantics under `DBInterface.transaction`
  * `findUnique` returning `nothing` when no match
* **Bulk‐insert** and **bulk‐update** helper tests

---

## 🔧 Migration Notes

* **Breaking**: `findMany(...; include=[...])` now returns `Vector{Dict{String,Any}}` instead of plain model instances. Update your callers accordingly.
* QueryBuilder functions have been renamed—please replace any direct `buildSqlQuery` calls with the new prepared-statement builders.
* If you need multi-statement transactions, use the **low-level** `executeQuery(conn, ...)` variant with `useTransaction=false` inside a `DBInterface.transaction` block.


# OrionORM v0.4.0 Release Notes

I’m excited to share release 0.4.0 of OrionORM. This version reflects several months of hands‑on use in my personal projects.

## Real‑World Use

I’ve been using OrionORM to develop dashboards and APIs. Defining models at runtime, automatic migrations, and a simple API have made it easy to integrate into new projects without boilerplate.

## Key Features

* **Dynamic Models**: Define tables on the fly with the `Model` macro
* **Connection Pooling**: Efficient pool via `Pool` with automatic validation and refresh
* **CRUD Operations**: `create`, `findFirst`, `findMany`, `update`, `delete` plus bulk helpers
* **Relationships**: `hasMany`, `hasOne`, `belongsTo` work out of the box
* **Query Builder**: Chainable `where`, `include`, `orderBy`, `limit`, `offset`
* **Safe Escaping**: `sql_escape` guards against injection attacks
* **UUID Support**: Automatic UUID primary keys via `UUID()` column type
* **Logging**: Adjustable log level through `ORIONORM_LOG_LEVEL`

## Performance at a Glance

I ran benchmarks on a local machine (MySQL 8.0 on localhost, pool size 5, no network latency) inserting and querying 100 rows with four columns each (id, name ≈15 chars, email ≈30 chars, cpf 11 chars). I used **BenchmarkTools.jl**’s `@benchmark` macro and recommend a few warm‑up runs to avoid first‑run (TTFX) overhead.

| Operation | Median Latency |             Mean ± SD |    Memory | Allocs | Scenario                                                          |
| --------- | -------------: | --------------------: | --------: | -----: | ----------------------------------------------------------------- |
| INSERT    |       2.239 ms |   2.334 ms ± 0.305 ms | 19.02 KiB |    267 | 100 sequential inserts of 100 rows (4 columns per row)            |
| SELECT    |     427.950 µs | 480.242 µs ± 0.976 ms | 10.32 KiB |    131 | 100 sequential lookups by email on 100‑row table (4 columns each) |

## What’s Next

I’m also developing **OrionAuth.jl**, an authentication and authorization package built on OrionORM. It will include user roles, permissions, and JWT support to speed up secure API development.

Thank you for trying OrionORM. I hope it makes your projects simpler and more reliable!

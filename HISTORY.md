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

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

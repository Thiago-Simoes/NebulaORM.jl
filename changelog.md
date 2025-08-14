# Changelog

## [0.5.2] - 2025-08-06
### Fixed
- Refactor buildJoinClause: now uses the new qualifyColumn helper to automatically wrap table and column names in backticks and fully qualify them in all JOIN conditions, eliminating ambiguous-column errors and keeping the code clean and consistent.

## [0.5.1] - 2025-08-06
- Fixed UUID field bug

## [0.5.0] - 2025-08-01
### Added

* **QueryBuilder v2** with full support for prepared statements, nested filters (`AND`, `OR`, `not`), array operations (`in`, `notIn`), and pattern matching (`contains`, `startsWith`, `endsWith`).
* **LEFT JOIN** semantics for `include` in `findMany`/`findFirst`, ensuring parents without children are still returned.
* **Bulk‐insert helpers**:

  * `buildBatchInsertQuery(model, records)`
  * `createMany(model, records; chunkSize, transaction)`
  * `createManyAndReturn(model, records)`
  * `updateManyAndReturn(model, query, data)`
* **`Base.filter` alias** for `findMany`.
* Extensive **negative and edge‐case tests** covering error handling, QueryBuilder operators, include‐empty children, default timestamps, transaction rollback, and `findUnique` without throw.

### Changed

* **Connection pool** refactored: connection validation, auto-reconnect, safe release, and explicit support for long-lived transactions.
* **`executeQuery` unified API**:

  * **Low-level**: `executeQuery(conn, sql, params; useTransaction)` without closing `conn`.
  * **High-level**: `executeQuery(sql, params; useTransaction)` opens/closes `conn`.
  * Auto-detects **SELECT** → returns `DataFrame`, **INSERT/UPDATE/DELETE** → returns `Int` (rows affected), **DDL** → returns `Bool`.
  * Always closes prepared statements to eliminate “commands out of sync.”
* **`findMany` / `findFirst`**:

  * Support for `include=[Model]` returning `Dict{String,Any}` with both parent and child arrays.
  * Internally uses a single LEFT JOIN and post-processes `eachrow(df)` into model instances.
* **`create(model, data)`** now safely retrieves `LAST_INSERT_ID()` on the same connection, eliminating cross-process ID mixups.
* **`updateMany`** now returns only the records actually updated by primary key lookup, not by re-querying the original filter.
* **QueryBuilder JOINs** default to `LEFT JOIN` when `include` is used.

### Fixed

- **Resource leaks** and “commands out of sync”:
  - Prepared statements are always closed in a `finally` block.
  - Connections are released promptly after use.
- **Transaction rollback test** now correctly propagates exceptions from inside `DBInterface.transaction`.
* **`instantiate` errors** resolved by always using a `DataFrameRow` (`df[1, :]`) in `findFirst` instead of raw vectors.

### Breaking Changes
- **`findMany(...; include=[...])`** now returns `Vector{Dict{String,Any}}` (with `"Model"` and `"IncludeModel"` fields) instead of `Vector{Model}`.
- Public `QueryBuilder` functions (`buildSqlQuery`, etc.) have been replaced by the new prepared-statement builders (`buildSelectQuery`, `buildInsertQuery`, `buildUpdateQuery`, `buildDeleteQuery`).


## [0.3.5]
### Fixed
- Fixed reverse relationships, solving problems with multiple relationships.
  - Now relationship names are generated with the target and field names.

## [0.3.4]
### Fixed
- Fixed logLevel
- Removed DotEnv.load!() from init, preventing scope problems

## [0.3.2]
### Added
- Add Default constraint support

### Fixed
- Update date handling in SQL types

## [0.3.1]

### Style
- Remove deprecated macros for improved clarity and maintainability.
- Removed printlns.


## [0.3.0]
Unlike previous versions, this new release introduces **BREAKING CHANGES**.

### Improved
- Replaced the use of macros for creating the Model with a function-based approach. This change was implemented to prevent precompilation errors and improve overall reliability. Using functions instead of macros provides better error handling capabilities, clearer debugging information, and avoids issues that may arise from the macro expansion process during precompilation. This enhancement leads to a more robust and maintainable codebase.


## [0.2.7]
Package features are nearly complete for version 1, with release preparations underway.

### Fixed
- Fixed bug `Evaluation into the closed module `OrionORM` breaks incremental compilation`

## [0.2.5]
Package features are nearly complete for version 1, with release preparations underway.

### Fixed
- Fixed relationships definition error

### Test Summary
Test Summary:                   | Pass  Total  Time
OrionORM                       |   28     28  8.0s
  OrionORM Basic CRUD Tests    |   15     15  7.0s
  OrionORM Relationships Tests |    4      4  0.6s
  OrionORM Pagination Tests    |    9      9  0.4s
     Testing OrionORM tests passed 

## [0.2.4]
### Improved
- New relationships can be added without been declared before.

## [0.2.3]
- **More Complex SQL Operations**
  - Support for advanced filters, ordering, and pagination.
- **Security and SQL Injection Prevention**
  - Further input sanitization to complement prepared statements.

## [0.2.2]
### Added
- **Connection Pooling**
  - Implement a connection pool to improve performance and prevent database overload.
### Improved
- **Transaction Support**
  - Add transaction mechanisms (begin, commit, and rollback) for atomic operations.
- **Error Handling and Logging**
  - Improved exception handling and add logs to facilitate debugging.

## [0.2.1]
### Added
- **More Complex SQL Operations**
  - Support for advanced filters, ordering, and pagination.
- **SQL to Julia Type Mapping Expansion**
  - Include support for more types (e.g., DATE, TIMESTAMP, etc.).
## Improved
- **Type Mapping using Macros**
  - Each type can be declared using a macro, instead of a function.
- **Better folders/files organization**
  - Improved readability and maintainability

## [0.2.0]
### Added
- **Relationship between Models**
  - Support for relationships between models, like foreign key.

## [0.1.1] - 2025-02-18
### Added
- **Created a `changelog.md`**
- **Improved Readme and Documentation**
  - Now readme is complete and including license.
  - Implemented documentation using Documenter.jl.

## [0.1.0] - 2025-02-17
### Added
- **Database Connection**
  - Use of environment variables with DotEnv to configure the connection.
- **Table Creation and Migration**
  - `migrate!` function and `@Model` macro that automatically create models and tables.
- **Global Model Registry**
  - Storage of metadata in a global dictionary.
- **Column and Constraint Definitions via Macros**
  - Macros for `@PrimaryKey`, `@AutoIncrement`, `@NotNull`, and `@Unique`.
- **Basic CRUD Operations**
  - Functions for `create`, `update`, `delete`, `findMany`, `findFirst`, `findUnique`, among others.
- **Model Conversion and Instantiation**
  - Conversion of query results into model instances.
- **UUID Generation**
  - `generateUUID` function to create unique identifiers.
- **Prepared Statements**
  - Implemented prepared statements to enhance security and prevent SQL injection.

# Changelog

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
  - `generateUuid` function to create unique identifiers.
- **Prepared Statements**
  - Implemented prepared statements to enhance security and prevent SQL injection.

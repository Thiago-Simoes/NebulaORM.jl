## Implemented Features

### 1. Database Connection
- **1.1** Use of environment variables with DotEnv to configure the connection.

### 2. Table Creation and Migration
- **2.1** `migrate!` function and `@Model` macro that automatically create models and tables.

### 3. Global Model Registry
- Storage of metadata in a global dictionary.

### 4. Column and Constraint Definitions via Macros
- Macros for `@PrimaryKey`, `@AutoIncrement`, `@NotNull`, and `@Unique`.

### 5. Basic CRUD Operations
- Functions for `create`, `update`, `delete`, `findMany`, `findFirst`, `findUnique`, among others.

### 6. Model Conversion and Instantiation
- Conversion of query results into model instances.

### 7. UUID Generation
- `generateUuid` function to create unique identifiers.

---

## Features to Implement

### 1. Security and SQL Injection Prevention
- Implement `prepared statements` or input sanitization to avoid injections.

### 2. Transaction Support
- Add transaction mechanisms (`begin`, `commit`, and `rollback`) for atomic operations.

### 3. Connection Pooling
- Implement a `connection pool` to improve performance and prevent database overload.

### 4. Error Handling and Logging
- Improve exception handling and add `logs` to facilitate debugging.

### 5. SQL to Julia Type Mapping Expansion
- Include support for more types (e.g., `DATE`, `TIMESTAMP`, etc.).

### 6. More Complex SQL Operations
- Support for `joins`, `advanced filters`, `ordering`, and `pagination`.

### 7. Optimization for Large Datasets
- Review the use of `DataFrames` and consider alternatives for better performance with large datasets.

### 8. Macro Side Effects Review
- Adjust automatic execution (like calling `migrate!` within the `@Model` macro) to avoid surprises.

### 9. Base Function Overriding
- Rethink overriding functions (e.g., `Base.filter`) to avoid conflicts with the Julia ecosystem.
# Bulk Operations

OrionORM offers specialized functions for efficient, transactional bulk inserts and updates. These helpers minimize round-trips and leverage chunking to handle large datasets gracefully.

---

## 1. Batch Insert Query Builder

Generates a single SQL `INSERT` statement with placeholders for multiple records.

```julia
buildBatchInsertQuery(model::DataType,
                      records::Vector{Dict{String,Any}})
```

* **Arguments**:

  * `model`: your `DataType` (e.g., `User` or `Post`).
  * `records`: vector of `Dict` where each dict maps column names to values.

* **Returns**: `NamedTuple(sql, params)`:

  * `sql`: a string like

    ```sql
    INSERT INTO table_name (col1,col2,...) VALUES (?,?,?...),(?,?,?...),...
    ```
  * `params`: a flat `Vector{Any}` concatenating the values for all rows in order.

```julia
records = [Dict("name"=>"A","email"=>"a@e.com"),
           Dict("name"=>"B","email"=>"b@e.com")]
b = buildBatchInsertQuery(User, records)
# b.sql    => "INSERT INTO User (`name`,`email`) VALUES (?,?),(?,?)"
# b.params => ["A","a@e.com","B","b@e.com"]
```

---

## 2. `createMany` – Chunked, Transactional Inserts

```julia
createMany(model::DataType,
           data::Vector{<:Dict{String,Any}};
           chunkSize::Int=1000,
           transaction::Bool=true)
```

* **Arguments**:

  * `model`: the `DataType` to insert into.
  * `data`: vector of dicts for each record.
  * `chunkSize`: number of records per batch (default `1000`).
  * `transaction`: wrap each chunk in a transaction (default `true`).

* **Returns**: `true` on success.

**Example**:

```julia
records = [Dict("name"=>"User$(i)","email"=>"u$(i)@e.com") for i in 1:5000]
createMany(User, records; chunkSize=500)
```

This will execute 10 batches of 500 inserts each, each inside its own transaction.

---

## 3. `createManyAndReturn` – Insert & Fetch

```julia
createManyAndReturn(model::DataType,
                    data::Vector{Dict{String,Any}})
```

Performs `createMany(model, data)` and then calls `findMany(model)` to return all rows, including newly inserted ones.

---

## 4. `updateManyAndReturn` – Bulk Update & Fetch

```julia
updateManyAndReturn(model::DataType,
                    query::AbstractDict,
                    data::Dict{String,Any})
```

* **Arguments**:

  * `model`: the `DataType` to update.
  * `query`: filter dict identifying which rows to update.
  * `data`: dict of fields to update.

* **Returns**: `Vector{Model}`—instances matching the `primary key` values of updated rows.

**Example**:

```julia
# Update all users with name "Bob" to "Robert" and return them
updated = updateManyAndReturn(User,
                              Dict("where"=>Dict("name"=>"Bob")),
                              Dict("name"=>"Robert"))
```

---

## 5. Performance Tips

* **Adjust `chunkSize`** based on:

  * Database max packet sizes
  * Transaction latency
  * Memory constraints

* **Use a single large transaction** when atomicity is critical:

  ```julia
  conn = dbConnection()
  try
    DBInterface.transaction(conn) do
      executeQuery(conn, b.sql, b.params; useTransaction=false)
    end
  finally
    releaseConnection(conn)
  end
  ```

* **Benchmark** with `BenchmarkTools.jl` to find the sweet spot for your workload.

---

With these helpers, OrionORM can scale bulk data operations from hundreds to thousands of rows efficiently and safely.

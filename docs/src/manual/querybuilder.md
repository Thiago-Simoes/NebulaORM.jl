# Query Builder Reference

The **Query Builder** in OrionORM provides a flexible, Prisma-inspired syntax for constructing SQL queries in Julia. You can filter, sort, paginate, and include related records using simple Julia `Dict` definitions.

---

## 1. Introduction

Instead of writing raw SQL, you build a **query dictionary** that describes:

* **where**: filtering conditions
* **select**: specific columns to retrieve
* **include**: related models to join
* **orderBy**: sorting
* **limit** / **offset**: pagination

The ORM converts this dictionary into a prepared SQL statement and parameters, then maps the results back to your Julia structs (or `Dicts` when using `include`).

---

## 2. Basic Query Structure

Every dynamic query uses the function:

```julia
buildSelectQuery(::Type{<:ModelType}, query::Dict)
```

It returns a `NamedTuple(sql, params)` suitable for passing to `executeQuery`.

```julia
tuple = buildSelectQuery(User, Dict(
  "where" => Dict("active" => true),
  "orderBy" => Dict("createdAt" => "desc"),
  "limit" => 10
))
# tuple.sql    => "SELECT * FROM User WHERE active = ? ORDER BY createdAt desc LIMIT ?"
# tuple.params => [true, 10]
```

---

## 3. Filtering with `where`

The `where` key accepts a nested `Dict` describing conditions. Supported operators:

| Operator   | Julia syntax                      | SQL translation    |
| ---------- | --------------------------------- | ------------------ |
| Equals     | `"name"=>"Alice"`                 | `name = 'Alice'`   |
| gt / lt    | `"age"=>Dict("gt"=>18)`           | `age > 18`         |
| gte / lte  | `"score"=>Dict("gte"=>100)`       | `score >= 100`     |
| in / notIn | `"id"=>Dict("in"=>[1,2,3])`       | `id IN (1,2,3)`    |
| contains   | `"email"=>Dict("contains"=>"@")`  | `email LIKE '%@%'` |
| startsWith | `"name"=>Dict("startsWith"=>"A")` | `name LIKE 'A%'`   |
| endsWith   | `"name"=>Dict("endsWith"=>"son")` | `name LIKE '%son'` |

### 3.1 Nested Logic

You can combine multiple filters with `AND`, `OR`, and `not`:

```julia
# (age > 18 AND active = true) OR email contains "@example.com"
where = Dict(
  "OR" => [
    Dict("AND" => [Dict("age"=>Dict("gt"=>18)), Dict("active"=>true)]),
    Dict("email"=>Dict("contains"=>"@example.com"))
  ]
)
```

---

## 4. Selecting Specific Columns

Use the `select` key to retrieve only certain fields:

```julia
query = Dict(
  "select" => ["id","name","email"]
)
b = buildSelectQuery(User, query)
# SQL: SELECT id,name,email FROM User
```

If no `select` is provided, the builder defaults to `*` (all columns).

---

## 5. Sorting and Pagination

* **orderBy**: a `String` or `Dict` of `column=>"asc"/"desc"`
* **limit**: maximum number of rows
* **offset**: number of rows to skip

```julia
query = Dict(
  "orderBy" => Dict("createdAt"=>"desc"),
  "limit" => 20,
  "offset" => 40
)
```

Generates: `... ORDER BY createdAt desc LIMIT ? OFFSET ?`

---

## 6. Including Related Models

To fetch parent and child records in a single query, use the `include` key with a vector of models:

```julia
results = findMany(User; query=Dict(
  "include" => [Post],
  "where"   => Dict("active"=>true)
))
```

Under the hood, OrionORM uses a **LEFT JOIN** for each included model, ensuring users with no posts still appear. The return value is:

```julia
Vector{Dict{String,Any}}
# each element: Dict(
#   "User" => User(...),
#   "Post" => Vector{Post}(...)
# )
```

---

## 7. Example: Combined Query

```julia
q = Dict(
  "where"   => Dict("active"=>true, "age"=>Dict("gte"=>21)),
  "select"  => ["id","name"],
  "include" => [Post],
  "orderBy" => Dict("name"=>"asc"),
  "limit"   => 5
)

conn = dbConnection()
(b.sql, b.params) = buildSelectQuery(User, q)
results = executeQuery(conn, b.sql, b.params)
releaseConnection(conn)
```

This returns up to 5 active users aged 21+ with only their `id` and `name` fields, each enriched with their posts.

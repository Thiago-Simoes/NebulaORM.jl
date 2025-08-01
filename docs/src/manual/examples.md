# Examples & FAQ

This guide provides advanced usage patterns, real‑world scenarios, and answers to frequently asked questions when working with OrionORM.

---

## 1. Multiple Includes

Fetch a `User` with both `posts` and another related model, e.g. `Profile`:

```julia
results = findMany(User; query=Dict(
  "where"   => Dict("active"=>true),
  "include" => [Post, Profile]
))

# Each element:
# Dict(
#   "User"    => User(...),
#   "Post"    => Vector{Post}(...),
#   "Profile" => Profile(...)
# )
```

Or filter children before include:

```julia
results = findMany(User; query=Dict(
  "where"   => Dict("Post"=>Dict("contains"=>"Welcome")),
  "include" => [Post]
))
```

---

## 2. Raw SQL Fallback

When you need custom SQL not yet supported by the QueryBuilder, you can still prepare and execute manually:

```julia
sql = "SELECT u.id, u.name, COUNT(p.id) AS post_count"
     * " FROM User u LEFT JOIN Post p ON u.id=p.authorId"
     * " WHERE u.active = ? GROUP BY u.id"
params = [true]

df = executeQuery(sql, params)
# Map results manually:
users = [ (
    id         = row.id,
    name       = row.name,
    post_count = row.post_count
  ) for row in eachrow(df)
]
```

---

## 3. Composite Primary Keys

OrionORM supports tables with multiple primary keys. Example:

```julia
Model(
  :Membership,
  [
    ("userId", INTEGER(), [PrimaryKey()]),
    ("groupId", INTEGER(), [PrimaryKey()]),
    ("role",   TEXT(),    [NotNull()])
  ]
)
```

* **`findFirst`** and **`update`** require a `where` dict including both keys:

```julia
m = findFirst(Membership;
      query=Dict("where"=>Dict("userId"=>1, "groupId"=>10))
)
```

---

## 4. FAQ

**Q1: How do I chain multiple operators on one column?**
A: Wrap them in a `Dict`, e.g.:

```julia
findMany(User; query=Dict(
  "where" => Dict(
    "age" => Dict("gte"=>18, "lte"=>30)
  )
))
```

**Q2: Why doesn’t `findMany` return a vector of `Dict` for simple queries?**
A: Only queries with `include` return `Dict{String,Any}`. Otherwise you get a `Vector{Model}`.

**Q3: How to inspect the raw SQL generated?**
A:

```julia
b = buildSelectQuery(User, qdict)
println(b.sql)
println("Params: ", b.params)
```

**Q4: Can I use custom types or functions in filters?**
A: You can inject raw SQL via string in `where`:

```julia
findMany(User; query=Dict("where"=>"LENGTH(name) > 5"))
```

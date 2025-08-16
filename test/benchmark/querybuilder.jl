# /test/benchmark/include_benchmark.jl
using BenchmarkTools
using Random
using Dates
using OrionORM   # garantir que o pacote esteja usando o mesmo db/.env dos testes
using DBInterface

Model(:user, [
    ("id", INTEGER(), [PrimaryKey(), AutoIncrement()]),
    ("name", VARCHAR(50)),
    ("email", VARCHAR(200), [Unique()]), # Constraint inline
    ("cpf", VARCHAR(11))
  ],
  [],
  [ # Indexes
    ["id", "name"], # Index non-unique, using old syntax
    Index(columns=["name", "cpf"], unique=true), # New syntax with Index
    Dict("name" => "ux_user_email", "columns" => ["email", "cpf"], "unique" => true) # Named index using Dict syntax
  ]
)




##### TESTS #####
# === SELECT ===============================================================
q_select = Dict(
  # filtro: email contendo "@example.com" ou id > 100
  "where"   => Dict(
    "OR" => [
      Dict("email" => Dict("contains" => "@example.com")),
      Dict("id"    => Dict("gt"       => 100))
    ]
  ),
  "orderBy" => Dict("id" => "desc"),
  "limit"   => 10,
  "offset"  => 0
)

# uso:
(q_sql, q_params) = OrionORM.buildSelectQuery(user, q_select)
@benchmark (q_sql, q_params) = OrionORM.buildSelectQuery(user, q_select)
# → prepare(conn, q_sql); execute(conn, q_params)


# === INSERT ===============================================================
q_insert = Dict(
  "data" => Dict(
    "name"  => "Thiago",
    "email" => "thiago@example.com",
    "cpf"   => "00000000000"
  )
)

# uso:
ins = OrionORM.buildInsertQuery(user, q_insert["data"])
@benchmark ins = OrionORM.buildInsertQuery(user, q_insert["data"])
# → prepare(conn, ins.sql); execute(conn, ins.params)


# === UPDATE ===============================================================
q_update = Dict(
  "where" => Dict("id" => 42),
  "data"  => Dict(
    "name"  => "Thiago Novo",
    "email" => "thiago.novo@example.com"
  )
)

# uso:
upd = OrionORM.buildUpdateQuery(user, q_update["data"], q_update["where"])
@benchmark upd = OrionORM.buildUpdateQuery(user, q_update["data"], q_update["where"])
# → prepare(conn, upd.sql); execute(conn, upd.params)


# === DELETE ===============================================================
q_delete = Dict(
  "where" => Dict("id" => 42)
)

# uso:
del = OrionORM.buildDeleteQuery(user, q_delete["where"])
@benchmark del = OrionORM.buildDeleteQuery(user, q_delete["where"])
# → prepare(conn, del.sql); execute(conn, del.params)

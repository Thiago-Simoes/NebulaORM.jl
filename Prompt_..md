    📁 build/
    📄 make.jl
      🔹 Conteúdo:
        ```
        import Pkg
Pkg.activate(".")
using Documenter, OrionORM

push!(LOAD_PATH,"../src/")
makedocs(
    sitename="OrionORM.jl",
    modules=[OrionORM],
    pages = [
    "Home" => "index.md",
    "Manual" => ["manual/start.md", "manual/relationship.md"],
    "Reference" => ["Reference/API.md"]
    ]
)

        ```

    📁 src/
    📄 OrionORM.jl
      🔹 Conteúdo:
        ```
        module OrionORM

using DBInterface
using MySQL
using UUIDs
using DotEnv
using DataFrames
using Dates
using Logging

include("./pool.jl")
include("./dbconnection.jl")
include("./types.jl")
include("./keys.jl")
include("./others.jl")
include("./models.jl")
include("./relationships.jl")
include("./querybuilder.jl")
include("./crud.jl")


# ---------------------------
# Global registry for associating model metadata (using the model name as key)
const modelRegistry = Dict{Symbol, Model}()

# Global registry for associating model relationships (using the model name as key)
const relationshipsRegistry = Dict{Symbol, Vector{Relationship}}()
const __ORM_MODELS__ = Dict{Symbol, Tuple{Any, Any}}()
__ORM_INITIALIZED__ = false

    
# Automatic initialization only if not precompiling
function __init__()
    initLogger()
    global __ORM_INITIALIZED__ = true
end




export dbConnection, createTableDefinition, migrate!, dropTable!,
       Model, generateUuid,
       findMany, findFirst, findFirstOrThrow, findUnique, findUniqueOrThrow,
       create, update, upsert, delete, createMany, createManyAndReturn,
       updateMany, updateManyAndReturn, deleteMany, hasMany, belongsTo, hasOne,
       VARCHAR, TEXT, NUMBER, DOUBLE, FLOAT, INTEGER, UUID, DATE, TIMESTAMP, JSON, PrimaryKey, AutoIncrement, NotNull, Unique, Default


end  # module ORM

        ```

    📄 crud.jl
      🔹 Conteúdo:
        ```
        function initLogger()
    lvl = lowercase(get(ENV, "OrionORM_LOG_LEVEL", "error"))
    logLevel = lvl == "error" ? Logging.Error :
                     lvl == "warn"  ? Logging.Warn  :
                     lvl == "debug" ? Logging.Debug : Logging.Info
    global_logger(SimpleLogger(stderr, logLevel))
    @info "Logger configured" level=logLevel
end

"""
    executeQuery(conn::DBInterface.Connection, stmt::String, params::Vector{Any}=Any[]; useTransaction::Bool=true)

Prepare and execute a SQL statement on the given connection, returning the result as a `DataFrame`
for queries that return rows, or the raw result (e.g., number of affected rows) otherwise.

# Arguments
- `conn::DBInterface.Connection`: The database connection to use.
- `stmt::String`: The SQL query string to prepare.
- `params::Vector{Any}`: A vector of parameters to bind to the prepared statement (default: `Any[]`).
- `useTransaction::Bool`: Whether to run the statement inside a new transaction (default: `true`).
  When `false`, the statement is executed without starting a transaction—useful if you are already
  inside `DBInterface.transaction`.

# Returns
- A `DataFrame` if the underlying result is tabular.
- Otherwise, returns the raw result from `DBInterface.execute`, such as the number of affected rows.

# Throws
- Rethrows any exception raised during statement preparation or execution.

# Returns

- A `DataFrame` if the result is tabular.  
- Otherwise, the raw result (e.g. number of affected rows).
"""
function executeQuery(conn::DBInterface.Connection, sql::AbstractString, params::Vector{<:Any}=Any[]; useTransaction::Bool=true)
    stmt = DBInterface.prepare(conn, sql)
    try
        is_sel = startswith(uppercase(strip(sql)), "SELECT")
        result = if is_sel
            DBInterface.execute(stmt, params)
        else
            if useTransaction
                DBInterface.transaction(conn) do
                    DBInterface.execute(stmt, params)
                end
            else
                DBInterface.execute(stmt, params)
            end
        end
        if is_sel
            return DataFrame(result)
        elseif startswith(uppercase(strip(sql)), "INSERT") || startswith(uppercase(strip(sql)), "UPDATE") || startswith(uppercase(strip(sql)), "DELETE")
            return result.rows_affected
        else
            return Bool(result)
        end
    finally
        try DBInterface.close!(stmt) catch _ end
    end
end

function executeQuery(sql::AbstractString, params::Vector{<:Any}=Any[]; useTransaction::Bool=true)
    conn = dbConnection()
    try
        return executeQuery(conn, sql, params; useTransaction=useTransaction)
    finally
        releaseConnection(conn)
    end
end


function dropTable!(conn::DBInterface.Connection, tableName::String)
    try
        sql = "DROP TABLE IF EXISTS `$tableName`"
        DBInterface.execute(conn, sql)
        return nothing
    catch e
        @error "Failed to drop table" exception=(e,) table=tableName
        rethrow(e)
    end
end

function findMany(model::DataType; query::AbstractDict=Dict())
    qdict    = normalizeQuery(query)
    resolved = resolveModel(model)
    conn     = dbConnection()
    try
        b    = buildSelectQuery(resolved, qdict)
        df   = executeQuery(conn, b.sql, b.params)
        recs = [instantiate(resolved, row) for row in eachrow(df)]
        if haskey(qdict, "include")
            out = Vector{Dict{String,Any}}()
            for rec in recs
                m = Dict{String,Any}(string(resolved)=>rec)
                for inc in qdict["include"]
                    incModel = isa(inc,String) ? Base.eval(@__MODULE__, Symbol(inc)) : inc
                    for rel in getRelationships(resolved)
                        if resolveModel(rel.targetModel) === incModel
                            val = rel.type == :hasMany    ? hasMany(rec, rel.field)    :
                                  rel.type == :hasOne    ? hasOne(rec, rel.field)     :
                                  rel.type == :belongsTo ? belongsTo(rec, rel.field)  :
                                                           nothing
                            m[string(incModel)] = val
                            break
                        end
                    end
                end
                push!(out, m)
            end
            return out
        end
        return recs
    finally
        releaseConnection(conn)
    end
end

function findFirst(model::DataType; query::AbstractDict = Dict())
    qdict    = normalizeQuery(query)
    resolved = resolveModel(model)

    if !haskey(qdict, "limit")
        qdict["limit"] = 1
    end

    try
        b = buildSelectQuery(resolved, qdict)    # NamedTuple(sql, params)
        df = executeQuery(b.sql, b.params)   # já retorna DataFrame

        isempty(df) && return nothing
        
        record = instantiate(resolved, df[1, :])

        if haskey(qdict, "include")
            result = Dict{String,Any}()
            result[string(resolved)] = record

            for included in qdict["include"]
                includedModel = isa(included, String) ? Base.eval(@__MODULE__, Symbol(included)) : included

                for rel in getRelationships(resolved)
                    if resolveModel(rel.targetModel) === includedModel
                        related = nothing
                        if rel.type == :hasMany
                            related = hasMany(record, rel.field)
                        elseif rel.type == :hasOne
                            related = hasOne(record, rel.field)
                        elseif rel.type == :belongsTo
                            related = belongsTo(record, rel.field)
                        end
                        result[string(includedModel)] = related
                        break
                    end
                end
            end

            return result
        end
        return record
    catch e
        rethrow(e)
    end
end


"""
    findUnique(model::DataType, uniqueField, value; query=Dict())

Finds a single record by a unique field. Returns an instance of the model if found,
or `nothing` if no matching record exists.
"""
function findUnique(model::DataType, uniqueField, value; query::AbstractDict=Dict())
    qdict    = normalizeQuery(query)
    resolved = resolveModel(model)

    if haskey(qdict, "where")
        if qdict["where"] isa Dict
            qdict["where"][uniqueField] = value
        else
            error("The 'where' field must be a Dict")
        end
    else
        qdict["where"] = Dict(uniqueField => value)
    end

    if !haskey(qdict, "limit")
        qdict["limit"] = 1
    end

    try
        b    = buildSelectQuery(resolved, qdict)
        df   = executeQuery(b.sql, b.params)
        isempty(df) && return nothing
        return instantiate(resolved, first(df))
    catch e
        rethrow(e)
    end
end


"""
    create(model::DataType, data::Dict{String,Any})

Inserts a new record for `model`, auto-generating UUIDs when needed,
and returns the created instance.
"""
function create(model::DataType, data::Dict{<:AbstractString,Any})
    resolved = resolveModel(model)
    meta     = modelConfig(resolved)
    allowed  = Set(String.(fieldnames(resolved)))
    filtered = Dict(k=>v for (k,v) in data if k in allowed)

    # gera UUID automático
    for col in meta.columns
        if occursin("VARCHAR(36)" ,col.type) &&
           "UUID" in uppercase(join(col.constraints," ")) &&
           !haskey(filtered,col.name)
            filtered[col.name] = generateUuid()
        end
    end

    conn = dbConnection()
    inserted_id = nothing
    try
        # 1) INSERT dentro de TRANSACTION implícito
        b = buildInsertQuery(resolved, filtered)
        executeQuery(conn, b.sql, b.params; useTransaction=true)

        # 2) pega o ID gerado na MESMA conexão
        df = executeQuery(conn, "SELECT LAST_INSERT_ID() AS id", [];
                          useTransaction=false)
        inserted_id = df.id[1]
    finally
        releaseConnection(conn)
    end

    # 3) busca e retorna o registro criado
    return findFirst(resolved; query=Dict("where"=>Dict(getPrimaryKeyColumn(resolved).name=>inserted_id)))
end


"""
    update(model::DataType, query::AbstractDict, data::Dict{String,Any})

Updates records in `model` matching `query["where"]` with the fields in `data`,
and returns the first updated instance.
"""
function update(model::DataType, query::AbstractDict, data::Dict{<:AbstractString,<:Any})
    qdict    = normalizeQuery(query)
    resolved = resolveModel(model)

    if !haskey(qdict, "where")
        error("Query dict must have a 'where' clause for update")
    end

    try
        b    = buildUpdateQuery(resolved, data, qdict["where"])
        executeQuery(b.sql, b.params)
        return findFirst(resolved; query=qdict)
    catch e
        rethrow(e)
    end
end


"""
    upsert(model::DataType, uniqueField, value, data::Dict{String,Any})

Creates a new record if none exists with the given unique field, otherwise updates the existing record.
"""
function upsert(model::DataType, uniqueField, value, data::Dict{<:AbstractString,<:Any})
    resolved = resolveModel(model)
    existing = findUnique(resolved, uniqueField, value)
    if isnothing(existing)
        return create(resolved, data)
    else
        q = Dict("where" => Dict(uniqueField => value))
        return update(resolved, q, data)
    end
end


"""
    delete(model::DataType, query::AbstractDict)

Deletes records in `model` matching `query["where"]` and returns `true` on success.
"""
function delete(model::DataType, query::AbstractDict)
    qdict = normalizeQuery(query)
    if !haskey(qdict, "where")
        error("Query dict must have a 'where' clause for delete")
    end

    try
        b    = buildDeleteQuery(resolveModel(model), qdict["where"])
        executeQuery(b.sql, b.params)
        return true
    catch e
        rethrow(e)
    end
end


"""
    buildBatchInsertQuery(model::DataType, records::Vector{Dict{String,Any}})

Generates a single INSERT statement with placeholders for multiple records,
returning (sql, params) suitable for prepared execution.
"""
function buildBatchInsertQuery(model::DataType, records::AbstractVector)
    meta     = modelConfig(model)
    colsList = [c.name for c in meta.columns if c.name != "id"]
    cols = join(["`$(c)`" for c in colsList], ", ")
    rowCount = length(records)
    singleRowPh = "(" * join(fill("?", length(colsList)), ",") * ")"
    allPh = join(fill(singleRowPh, rowCount), ",")
    sql = "INSERT INTO $(meta.name) ($cols) VALUES $allPh"
    params = reduce(vcat, [ [r[c] for c in colsList] for r in records ])
    return (sql=sql, params=params)
end


"""
    createMany(model::DataType, data::Vector{<:Dict};
               chunkSize::Int=1000, transaction::Bool=true)

Inserts multiple records in batches. Returns `true` on success.
"""
function createMany(model::DataType, data::Vector{<:Dict{String,<:Any}};
                    chunkSize::Int=1000, transaction::Bool=true)
    resolved = resolveModel(model)
    conn = dbConnection()
    try
        if transaction
            DBInterface.transaction(conn) do
                for chunk in Iterators.partition(data, chunkSize)
                    b    = buildBatchInsertQuery(resolved, chunk)
                    executeQuery(conn, b.sql, b.params; useTransaction=false)
                end
            end
        else
            for chunk in Iterators.partition(data, chunkSize)
                b    = buildBatchInsertQuery(resolved, vec(chunk))
                executeQuery(conn, b.sql, b.params; useTransaction=false)
            end
        end
        return true
    finally
        releaseConnection(conn)
    end
end


"""
    updateMany(model::DataType, query, data::Dict{String,Any})

Updates all records matching `query["where"]` with the given `data`
and returns the updated instances.
"""
function updateMany(model::DataType, queryDt::AbstractDict, data::Dict{<:AbstractString,<:Any})
    qdict    = normalizeQuery(queryDt)
    if !haskey(qdict, "where")
        error("Query dict must have a 'where' clause for updateMany")
    end
    resolved = resolveModel(model)
    pkcol    = getPrimaryKeyColumn(resolved)
    pkcol === nothing && error("No primary key defined for model $(resolved)")
    original = findMany(resolved; query=queryDt)
    ids      = [getfield(r, Symbol(pkcol.name)) for r in original]
    b        = buildUpdateQuery(resolved, data, qdict["where"])
    executeQuery(b.sql, b.params)
    return findMany(resolved; query=Dict("where" => Dict(pkcol.name => Dict("in" => ids))))
end

"""
    updateManyAndReturn(model::DataType, query::AbstractDict, data::Dict{String,Any})

Updates all records in `model` matching `query["where"]` with the values in `data`
and returns the updated instances.
"""
function updateManyAndReturn(model::DataType, query::AbstractDict, data::Dict{<:AbstractString,<:Any})
    qdict = normalizeQuery(query)
    if !haskey(qdict, "where")
        error("Query dict must have a 'where' clause for updateManyAndReturn")
    end
    resolved = resolveModel(model)
    try
        b    = buildUpdateQuery(resolved, data, qdict["where"])
        executeQuery(b.sql, b.params)
        return findMany(resolved; query=qdict)
    catch e
        rethrow(e)
    end
end

"""
    deleteMany(model::DataType, query::AbstractDict=Dict())

Deletes all records in `model` matching `query["where"]` and returns `true` on success.
"""
function deleteMany(model::DataType, query::AbstractDict=Dict())
    qdict = normalizeQuery(query)
    if !haskey(qdict, "where")
        error("Query dict must have a 'where' clause for deleteMany")
    end
    resolved = resolveModel(model)
    try
        b    = buildDeleteQuery(resolved, qdict["where"])
        executeQuery(b.sql, b.params)
        return true
    catch e
        rethrow(e)
    end
end

# Métodos de instância já utilizam as funções acima
"""
    update(modelInstance)

Updates the record corresponding to `modelInstance` in the database
using its primary key, and returns the updated instance.
"""
function update(modelInstance)
    modelType = typeof(modelInstance)
    pkCol     = getPrimaryKeyColumn(modelType)
    pkCol === nothing && error("No primary key defined for $(modelType)")
    pkName    = pkCol.name
    id        = getfield(modelInstance, Symbol(pkName))
    data      = Dict{String,Any}(string(f) => getfield(modelInstance, f)
                                  for f in fieldnames(modelType))
    return update(modelType, Dict("where" => Dict(pkName => id)), data)
end

"""
    delete(modelInstance)

Deletes the record corresponding to `modelInstance` in the database
using its primary key, and returns `true` on success.
"""
function delete(modelInstance)
    modelType = typeof(modelInstance)
    pkCol     = getPrimaryKeyColumn(modelType)
    pkCol === nothing && error("No primary key defined for $(modelType)")
    pkName    = pkCol.name
    id        = getfield(modelInstance, Symbol(pkName))
    return delete(modelType, Dict("where" => Dict(pkName => id)))
end

import Base: filter

"""
    filter(model::DataType; kwargs...)

Filters records of `model` by the keyword arguments provided
and returns the matching instances.
"""
function filter(model::DataType; kwargs...)
    return findMany(model; query=Dict("where" => Dict(kwargs...)))
end

        ```

    📄 dbconnection.jl
      🔹 Conteúdo:
        ```
        using DotEnv
using MySQL
using DBInterface
using .Pool

# ---------------------------
# Connection to the database
# ---------------------------
function dbConnection()
    if isempty(Pool.connection_pool)
        Pool.init_pool()
    end
    return Pool.getConnection()
end

function releaseConnection(conn)
    Pool.releaseConnection(conn)
end

export releaseConnection, dbConnection
        ```

    📄 keys.jl
      🔹 Conteúdo:
        ```
        # ---------------------------
# This file contains the macros for the keys in the database.
# ---------------------------
function PrimaryKey() 
    :( "PRIMARY KEY" )
end

function AutoIncrement()
    :( "AUTO_INCREMENT" )
end

function NotNull()
    :( "NOT NULL" )
end

function Default(def)
    "DEFAULT $(def)"
end

function Unique()
    :( "UNIQUE" )
end

        ```

    📄 models.jl
      🔹 Conteúdo:
        ```
        using Dates

function createTableDefinition(model::Model)
    colDefs = String[]
    keyDefs = String[]
    for col in model.columns
        constraints = copy(col.constraints)
        colType = col.type
        if occursin("TEXT", colType) && "UNIQUE" in constraints
            deleteat!(constraints, findfirst(==("UNIQUE"), constraints))
            push!(keyDefs, "UNIQUE KEY (`$(col.name)`(191))")
        end
        push!(colDefs, "$(col.name) $(colType) $(join(constraints, " "))")
    end
    allDefs = join(colDefs, ", ")
    if !isempty(keyDefs)
        allDefs *= ", " * join(keyDefs, ", ")
    end
    return allDefs
end

function migrate!(conn, model::Model)
    schema = createTableDefinition(model)
    # Usar interpolação para o nome da tabela e schema; sem binding de valores para identificadores.
    query = "CREATE TABLE IF NOT EXISTS " * model.name * " (" * schema * ")"
    stmt = DBInterface.prepare(conn, query)
    DBInterface.execute(stmt, [])
end



"""
    Model(modelName::Symbol,
                columnsDef::Vector{<:Tuple{String,String,Vector{<:Any}}};
                relationshipsDef::Vector{<:Tuple{Symbol,Symbol,Symbol,Symbol}} = [])

Define um modelo em runtime, criando o `struct`, registrando-o no `modelRegistry`,
executando a migração e cadastrando relacionamentos.
"""
function Model(modelName::Symbol,
                     columnsDef::Vector,
                     relationshipsDef::Vector = [])

    # 1) Monta os campos do struct com tipos Julia
    field_exprs = Vector{Expr}()
    for (col_name, sql_type, _) in columnsDef
        julia_ty = mapSqlTypeToJulia(sql_type)
        push!(field_exprs, :( $(Symbol(col_name))::$(julia_ty) ))
    end

    # 2) Define dinamicamente o mutable struct com @kwdef
    struct_expr = quote
        Base.@kwdef mutable struct $(modelName)
            $(field_exprs...)
        end
    end
    @eval Main $struct_expr   # injeta no módulo Main

    columns_vec = [ Column(name, sql_type, constraints) 
                    for (name, sql_type, constraints) in columnsDef ]

    model_meta = Model(string(modelName), columns_vec, getfield(Main, modelName))
    modelRegistry[Symbol(modelName)] = model_meta
    conn = dbConnection()
    migrate!(conn, model_meta)

    if !isempty(relationshipsDef)
        rel_objs = Relationship[]
        for (fld, tgt, tgtfld, rtype) in relationshipsDef
            push!(rel_objs,
                 Relationship(string(fld), Symbol(tgt), string(tgtfld), rtype))
            rev_type::Symbol = ((rtype == :belongsTo) ? :hasMany : (rtype == :hasMany ? :belongsTo : rtype))
            rev_rel = Relationship("reverse_$(fld)_$(modelName)", modelName, string(fld), rev_type)
            arr = get!(relationshipsRegistry, Symbol(tgt), Relationship[])
            push!(arr, rev_rel)
            relationshipsRegistry[Symbol(tgt)] = arr
        end
        relationshipsRegistry[Symbol(modelName)] = rel_objs
    end

    return getfield(Main, modelName) # retorna o tipo criado
end


function resolveModel(modelRef)
    if modelRef isa QuoteNode
        modelRef = modelRef.value
    end
    if modelRef isa Symbol
        ret::DataType = Base.eval(Main, modelRef)
        return ret
    elseif modelRef isa DataType
        return modelRef
    else
        error("Referência de modelo inválida: $modelRef")
    end
end

# ---------------------------
# Helpers: Metadados e conversão de registros
# ---------------------------
function modelConfig(model::DataType)
    local key = nameof(model)
    if haskey(modelRegistry, key)
        return modelRegistry[key]
    else
        error("Model $(key) not registered")
    end
end

function getRelationships(model::DataType)
    local key = nameof(model)
    return get(relationshipsRegistry, key, [])
end

function getPrimaryKeyColumn(model::DataType)
    meta = modelConfig(model)
    for col in meta.columns
        if occursin("PRIMARY KEY", uppercase(join(col.constraints, " ")))
            return col
        end
    end
    return nothing
end

function convertRowToDict(row, model::DataType)
    meta = modelConfig(model)
    d = Dict{String,Any}()
    for (i, col) in enumerate(meta.columns)
        d[col.name] = row[i]
    end
    return d
end

function instantiate(model::DataType, record::Union{DataFrame, DataFrameRow})
    meta = modelConfig(model)
    args = []
    for (i, col) in enumerate(meta.columns)
        value = record[i]
        if ismissing(value)
            if col.type == "INTEGER"
                push!(args, 0)
            elseif col.type in ["FLOAT", "DOUBLE"]
                push!(args, 0.0)
            elseif col.type == "VARCHAR(36)" || col.type == "TEXT" || col.type == "JSON"
                push!(args, "")
            elseif col.type == "DATE"
                push!(args, Date("1900-01-01"))
            elseif col.type == "TIMESTAMP"
                push!(args, DateTime("1900-01-01T00:00:00"))
            else
                push!(args, nothing)
            end
        else
            push!(args, value)
        end
    end
    return model(args...)
end

        ```

    📄 others.jl
      🔹 Conteúdo:
        ```
        function getLastInsertId()
    conn = dbConnection()
    result = DBInterface.execute(conn, "SELECT LAST_INSERT_ID() as id") |> DataFrame
    row = first(result)
    releaseConnection(conn)
    return row.id |> Int
end


function serialize(instance)
    local d = Dict{String,Any}()
    for field in fieldnames(typeof(instance))
        d[string(field)] = getfield(instance, field)
    end
    return d
end


function generateUuid()
    return string(uuid4())
end

        ```

    📄 pool.jl
      🔹 Conteúdo:
        ```
        module Pool

using DBInterface
using MySQL
using DotEnv

# Lê POOL_SIZE do ENV ou usa 5 se não definido
const POOL_SIZE = get(ENV, "POOL_SIZE", "5") |> x -> parse(Int, x)
const connection_pool = Channel{MySQL.Connection}(POOL_SIZE)

# Cria uma nova conexão
function create_connection()
    dbHost     = ENV["DB_HOST"]
    dbUser     = ENV["DB_USER"]
    dbPassword = ENV["DB_PASSWORD"]
    dbName     = ENV["DB_NAME"]
    dbPort     = parse(Int, string(ENV["DB_PORT"]))
    return DBInterface.connect(MySQL.Connection, dbHost, dbUser, dbPassword, db=dbName, port=dbPort, reconnect=true)
end

function init_pool()
    # Limpa conexões existentes, se houver
    while isready(connection_pool)
        take!(connection_pool)
    end
    # DotEnv.load!()  # se necessário
    for _ in 1:POOL_SIZE
        conn = create_connection()
        put!(connection_pool, conn)
    end
end

# Verifica se a conexão está ativa; se não, cria nova.
function validate_connection(conn)
    try
        DBInterface.execute(conn, "SELECT 1")
        return conn
    catch
        return create_connection()
    end
end

function getConnection()
    local conn = take!(connection_pool) |> validate_connection

    # Verifica se conexões disponíveis estão abaixo da metade do pool
    if connection_pool.n_avail_items < ceil(Int, POOL_SIZE / 2)
        Threads.@spawn :interactive begin
            while length(connection_pool) < POOL_SIZE
                new_conn = create_connection()
                put!(connection_pool, new_conn)
            end
        end
    end
    return conn
end

function releaseConnection(conn::MySQL.Connection)
    if connection_pool.n_avail_items < POOL_SIZE
        put!(connection_pool, conn)
    else
        try
            DBInterface.close(conn)
        catch e
            @warn "Failed to close extra connection" exception=(e,)
        end
    end
end

export init_pool, getConnection, releaseConnection, connection_pool

end # module Pool

        ```

    📄 querybuilder.jl
      🔹 Conteúdo:
        ```
        # ---------------------------
# Query Builder Inspired by Prisma.io
# ---------------------------
# ---------------------------
# Query Builder – versão 2 (prepared)
# ---------------------------

# === WHERE ===============================================================

"""
    _build_where(where)::NamedTuple{(:clause,:params)}

Recebe qualquer Dict compatível com a sintaxe Prisma e devolve
`clause::String` (com placeholders `?`) e `params::Vector` na ordem certa.
"""
function _build_where(whereDef)::NamedTuple{(:clause,:params)}
    conds  = String[]
    params = Any[]

    for (k,v) in whereDef
        ks = string(k)

        if ks == "AND" || ks == "OR"
            sub = [_build_where(x) for x in v]
            joined = join(["(" * s.clause * ")" for s in sub], " $ks ")
            append!(params, reduce(vcat, [s.params for s in sub], init = Any[]))
            push!(conds, joined)

        elseif ks == "not"
            sub = _build_where(v)
            push!(conds, "NOT (" * sub.clause * ")")
            append!(params, sub.params)

        elseif ks == "isNull"
            # v deve ser algo como ["colName"]
            push!(conds, "$(first(v)) IS NULL")

        else
            # ou é operador de array no nível de coluna
            if v isa Dict
                for (op,val) in v
                    opos = string(op)

                    if opos == "gt"
                        push!(conds, "`$ks` > ?");   push!(params, val)
                    elseif opos == "gte"
                        push!(conds, "`$ks` >= ?");  push!(params, val)
                    elseif opos == "lt"
                        push!(conds, "`$ks` < ?");   push!(params, val)
                    elseif opos == "lte"
                        push!(conds, "`$ks` <= ?");  push!(params, val)
                    elseif opos == "eq"
                        push!(conds, "`$ks` = ?");   push!(params, val)

                    elseif opos == "contains"
                        push!(conds, "`$ks` LIKE ?");  push!(params, "%$(val)%")
                    elseif opos == "startsWith"
                        push!(conds, "`$ks` LIKE ?");  push!(params, "$(val)%")
                    elseif opos == "endsWith"
                        push!(conds, "`$ks` LIKE ?");  push!(params, "%$(val)")

                    elseif opos == "in"
                        ph = join(fill("?", length(val)), ",")
                        push!(conds, "`$ks` IN ($ph)"); append!(params, val)
                    elseif opos == "notIn"
                        ph = join(fill("?", length(val)), ",")
                        push!(conds, "`$ks` NOT IN ($ph)"); append!(params, val)

                    else
                        error("Operador desconhecido $opos")
                    end
                end

            else
                # caso simples campo = valor
                push!(conds, "$ks = ?")
                push!(params, v)
            end
        end
    end

    return (clause = join(conds, " AND "), params = params)
end


# === JOIN ================================================================

function _build_join(root::DataType, include)::NamedTuple
    joins = String[]
    seen  = Set{Symbol}()
    for inc in include
        rels = getRelationships(root)
        wanted = Symbol(isa(inc, String) ? inc : nameof(inc))
        rel = findfirst(r->resolveModel(r.targetModel) === resolveModel(wanted), rels)
        isnothing(rel) && error("No relationship to $(wanted) from $(root)")
        _, incModel, cond = buildJoinClause(root, rels[rel])
        incTable = modelConfig(incModel).name
        push!(joins, " LEFT JOIN $incTable ON $cond ")
        push!(seen, wanted)
    end
    return (sql = join(joins, ""), seen = seen)
end

# === SELECT ==============================================================
function _build_select(baseTable::AbstractString, query)::String
    if haskey(query,"select")
        return join(query["select"],", ")
    elseif haskey(query,"include")
        return "$baseTable.*"
    else
        return "*"
    end
end

# === ORDER ===============================================================
function _build_order(order)::AbstractString
    if order isa String
        return order                       # já veio validado
    elseif order isa Dict
        (col,dir) = first(order)
        dir = uppercase(string(dir)) in ("ASC","DESC") ? dir : "ASC"
        return "$col $dir"
    else
        error("orderBy deve ser String ou Dict")
    end
end

# === MAIN BUILDER ========================================================
function buildJoinClause(rootModel::DataType, rel::Relationship)
    local rootTable = modelConfig(rootModel).name
    local includedModel = resolveModel(rel.targetModel)
    
    # Verifica se o modelo incluído está registrado; caso contrário, lança um erro.
    if !haskey(modelRegistry, nameof(includedModel))
        error("Model $(nameof(includedModel)) not registered")
    end
    local includedTable = modelRegistry[nameof(includedModel)].name

    if rel.type in (:hasMany, :hasOne)
        local pkCol = getPrimaryKeyColumn(rootModel)
        if pkCol === nothing
            error("No primary key for model $(rootModel)")
        end
        local joinCondition = "$rootTable." * pkCol.name * " = $includedTable." * rel.targetField
        return ("INNER", includedModel, joinCondition)
    elseif rel.type == :belongsTo
        local parentPk = getPrimaryKeyColumn(includedModel)
        if parentPk === nothing
            error("No primary key for model $(includedModel)")
        end
        local joinCondition = "$includedTable." * parentPk.name * " = $rootTable." * rel.field
        return ("INNER", includedModel, joinCondition)
    else
        error("Unknown relationship type $(rel.type)")
    end
end


"""
    buildSqlQuery(model::DataType, query::Dict)

Devolve `(sql,params)` prontos para `DBInterface.prepare/execute`.
"""
function buildSelectQuery(model::DataType, query::Dict)::NamedTuple{(:sql,:params)}
    baseTable = modelConfig(model).name
    select    = _build_select(baseTable, query)
    sql       = "SELECT $select FROM $baseTable"
    params    = Any[]

    # JOIN / INCLUDE
    if haskey(query,"include")
        j = _build_join(model, query["include"])
        sql *= j.sql
    end

    # WHERE
    if haskey(query,"where")
        w = _build_where(query["where"])
        sql    *= " WHERE " * w.clause
        append!(params, w.params)
    end

    # ORDER / LIMIT / OFFSET
    if haskey(query,"orderBy"); sql *= " ORDER BY " * _build_order(query["orderBy"]) end
    if haskey(query,"limit");   sql *= " LIMIT ?" ; push!(params, query["limit"])    end
    if haskey(query,"offset");  sql *= " OFFSET ?" ; push!(params, query["offset"])  end

    return (sql = sql, params = params)
end


"""
    buildInsertQuery(model::DataType, data::Dict{String,Any})

Gera:
  sql    = "INSERT INTO table (col1,col2,…) VALUES (?,?,…)"
  params = [val1, val2, …]
"""
function buildInsertQuery(model::DataType, data::Dict{<:AbstractString,<:Any})
    meta   = modelConfig(model)
    cols   = String[]
    phs    = String[]
    params = Any[]
    for (k,v) in data
        push!(cols, "`$k`")
        push!(phs, "?")
        push!(params, v)
    end
    tbl    = meta.name
    sql    = "INSERT INTO $tbl (" * join(cols, ",") * ") VALUES (" * join(phs, ",") * ")"
    return (sql=sql, params=params)
end


"""
    buildUpdateQuery(model::DataType, data::Dict, where::Dict)

Gera:
  sql    = "UPDATE table SET col1 = ?, col2 = ? WHERE (…)"
  params = [val1, val2, …, [where-params…]]
"""
function buildUpdateQuery(model::DataType, data::Dict{<:AbstractString,<:Any}, query::Dict{<:AbstractString,<:Any})
    meta      = modelConfig(model)
    assigns   = String[]
    params    = Any[]
    for (k,v) in data
        push!(assigns, "`$k` = ?")
        push!(params, v)
    end
    # reaproveita o _build_where para o WHERE
    w = _build_where(query)
    tbl   = meta.name
    sql   = "UPDATE $tbl SET " * join(assigns, ", ") * " WHERE " * w.clause
    append!(params, w.params)
    return (sql=sql, params=params)
end


"""
    buildDeleteQuery(model::DataType, where::Dict)

Gera:
  sql    = "DELETE FROM table WHERE (…)"; params = [where-params…]
"""
function buildDeleteQuery(model::DataType, query::Dict{<:AbstractString,<:Any})
    meta   = modelConfig(model)
    w      = _build_where(query)
    sql    = "DELETE FROM " * meta.name * " WHERE " * w.clause
    return (sql=sql, params=w.params)
end



# Mantém compatibilidade com chamadas antigas (sem Dict → retorno igual)
normalizeQuery(q::AbstractDict) = Dict{String,Any}(string(k)=>v for (k,v) in q)
normalizeQuery(q::NamedTuple) = Dict{String,Any}(string(k)=>v for (k,v) in pairs(q))


        ```

    📄 relationships.jl
      🔹 Conteúdo:
        ```
        
# ---------------------------
# Relationship Helper Functions
# ---------------------------
# Versão registrada (usando metadados)
function hasMany(parentInstance, relationName)
    parentType = typeof(parentInstance)
    relationships = getRelationships(parentType)
    for rel in relationships
        if rel.field == relationName && rel.type == :hasMany
            pkCol = getPrimaryKeyColumn(parentType)
            if pkCol === nothing
                error("No primary key defined for model $(parentType)")
            end
            parentValue = getfield(parentInstance, Symbol(pkCol.name))
            return findMany(resolveModel(rel.targetModel); query=Dict("where" => Dict(rel.targetField => parentValue)))
        end
    end
    error("No hasMany relationship found with name $relationName for model $(parentType)")
end

# Overload para hasMany com 3 parâmetros
function hasMany(parentInstance, relatedModel::DataType, foreignKey::String)
    local parentType = typeof(parentInstance)
    local pkCol = getPrimaryKeyColumn(parentType)
    if pkCol === nothing
        error("No primary key defined for model $(parentType)")
    end
    local parentValue = getfield(parentInstance, Symbol(pkCol.name))
    return findMany(relatedModel; query=Dict("where" => Dict(foreignKey => parentValue)))
end

# Versão registrada para belongsTo
function belongsTo(childInstance, relationName)
    childType = typeof(childInstance)
    relationships = getRelationships(childType)
    for rel in relationships
        if rel.field == relationName && rel.type == :belongsTo
            childFKValue = getfield(childInstance, Symbol(rel.field))
            return findFirst(resolveModel(rel.targetModel); query=Dict("where" => Dict(rel.targetField => childFKValue)))
        end
    end
    error("No belongsTo relationship found with name $relationName for model $(childType)")
end

# Overload para belongsTo com 3 parâmetros
function belongsTo(childInstance, relatedModel::DataType, foreignKey::String)
    local childValue = getfield(childInstance, Symbol(foreignKey))
    local pk = getPrimaryKeyColumn(relatedModel)
    if pk === nothing
        error("No primary key defined for model $(relatedModel)")
    end
    return findFirst(relatedModel; query=Dict("where" => Dict(pk.name => childValue)))
end

# Versão registrada para hasOne
function hasOne(parentInstance, relationName)
    parentType = typeof(parentInstance)
    relationships = getRelationships(parentType)
    for rel in relationships
        if rel.field == relationName && rel.type == :hasOne
            pkCol = getPrimaryKeyColumn(parentType)
            if pkCol === nothing
                error("No primary key defined for model $(parentType)")
            end
            local parentValue = getfield(parentInstance, Symbol(pkCol.name))
            return findFirst(resolveModel(rel.targetModel); query=Dict("where" => Dict(rel.targetField => parentValue)))
        end
    end
    error("No hasOne relationship found with name $relationName for model $(parentType)")
end

# Overload para hasOne com 3 parâmetros
function hasOne(parentInstance, relatedModel::DataType, foreignKey::String)
    local parentType = typeof(parentInstance)
    local pkCol = getPrimaryKeyColumn(parentType)
    if pkCol === nothing
        error("No primary key defined for model $(parentType)")
    end
    local parentValue = getfield(parentInstance, Symbol(pkCol.name))
    return findFirst(relatedModel; query=Dict("where" => Dict(foreignKey => parentValue)))
end
        ```

    📄 types.jl
      🔹 Conteúdo:
        ```
        using Dates

# Pre-defined SQL type constructors
# Are macros 
function VARCHAR(size)
    return "VARCHAR($(size))"
end

function TEXT()
    return :( "TEXT" )
end

function INTEGER()
    return :( "INTEGER" )
end

function DOUBLE()
    return :( "DOUBLE" )
end

function FLOAT()
    return :( "FLOAT" )
end

function UUID()
    return :( "VARCHAR(36)" )
end

function DATE()
    return :( "DATE" )
end

function TIMESTAMP()
    return :( "TIMESTAMP" )
end

function JSON()
    return :( "JSON" )
end

# ---------------------------
# Base structs
# ---------------------------
Base.@kwdef mutable struct Column
    name::String
    type::String
    constraints::Vector{String} = String[]
end

Base.@kwdef mutable struct Model
    name::String
    columns::Vector{Column}
    modelType::DataType
end

Base.@kwdef mutable struct Relationship
    field::String
    targetModel::Union{DataType, Symbol, QuoteNode}
    targetField::String
    type::Symbol  # :hasOne, :hasMany, :belongsTo
end


# ---------------------------
# Type functions
# ---------------------------
# ---------------------------
function mapSqlTypeToJulia(sqlType::String)
    sqlType = uppercase(sqlType)
    if sqlType == "INTEGER"
        return Int
    elseif sqlType in ["FLOAT", "DOUBLE"]
        return Float64
    elseif sqlType == "TEXT"
        return String
    elseif sqlType == "TIMESTAMP"
        return Dates.DateTime
    elseif sqlType == "DATE"
        return Dates.Date
    elseif sqlType == "JSON"
        return String
    elseif sqlType == "UUID"
        return String
    else
        return Any
    end
end

        ```

    📁 benchmark/
    📄 runtests.jl
      🔹 Conteúdo:
        ```
        # Implementa os testes unitários para o módulo `ORM.jl` e suas dependências.
import Pkg
Pkg.activate("..")
# ... incluir outros arquivos de teste conforme necessário ...

using Test
using Dates
using DotEnv

DotEnv.load!() 

using OrionORM

# Setup: Obter conexão e dropar as tabelas de teste, se existirem
conn = dbConnection()
dropTable!(conn, "User")
dropTable!(conn, "Post")
releaseConnection(conn)

# Define um modelo de teste com chave primária "id"
Model(
    :User,
    [
        ("id", INTEGER(), [PrimaryKey(), AutoIncrement()]),
        ("name", VARCHAR(50), [NotNull()]),
        ("email", TEXT(), [Unique(), NotNull()])
    ]
)

Model(
    :Post,
    [
        ("id", INTEGER(), [PrimaryKey(), AutoIncrement()]),
        ("title", TEXT(), [NotNull()]),
        ("authorId", INTEGER(), [NotNull()]),
        ("createdAt", TIMESTAMP(), [NotNull(), Default("CURRENT_TIMESTAMP()")])
    ],
    [
        ("authorId", User, "id", :belongsTo)
    ]
)


@testset verbose = true "OrionORM" begin
    @testset "OrionORM Basic CRUD Tests" begin
        # ------------------------------
        # Teste: Criar um registro
        # ------------------------------
        userData = Dict("name" => "Thiago", "email" => "thiago@example.com", "cpf" => "00000000000")
        user = create(User, userData)
        @test user.name == "Thiago"
        @test user.email == "thiago@example.com"
        @test hasproperty(user, :id)  # A chave primária deve estar definida

        # ------------------------------
        # Teste: Buscar registro com filtro (usando query dict)
        # ------------------------------
        foundUser = findFirst(User; query=Dict("where" => Dict("name" => "Thiago")))
        @test foundUser !== nothing
        @test foundUser.id == user.id

        # ------------------------------
        # Teste: Atualizar registro usando função update com query dict
        # ------------------------------
        updatedUser = update(User, Dict("where" => Dict("id" => user.id)), Dict("name" => "Thiago Updated"))
        @test updatedUser.name == "Thiago Updated"

        # ------------------------------
        # Teste: Upsert - atualizar se existir, criar se não existir
        # ------------------------------
        upsertUser = upsert(User, "email", "thiago@example.com",
                            Dict("name" => "Thiago Upserted", "email" => "thiago@example.com"))
        @test upsertUser.name == "Thiago Upserted"

        # ------------------------------
        # Teste: Atualizar registro via método de instância
        # ------------------------------
        foundUser.name = "Thiago Instance"
        updatedInstance = update(foundUser)
        @test updatedInstance.name == "Thiago Instance"

        # ------------------------------
        # Teste: Deletar registro via método de instância
        # ------------------------------
        deleteResult = delete(foundUser)
        @test deleteResult === true

        # ------------------------------
        # Teste: Criar múltiplos registros
        # ------------------------------
        records = [
            Dict("name" => "Bob", "email" => "bob@example.com", "cpf" => "11111111111"),
            Dict("name" => "Carol", "email" => "carol@example.com", "cpf" => "22222222222")
        ]
        createdRecords = createMany(User, records)
        @test createdRecords == true

        # ------------------------------
        # Teste: Buscar vários registros (query dict vazio)
        # ------------------------------
        manyUsers = findMany(User)
        @test length(manyUsers) ≥ 2

        # ------------------------------
        # Teste: Atualizar vários registros usando query dict
        # ------------------------------
        uMany = updateMany(User, Dict("where" => Dict("name" => "Bob")), Dict("name" => "Bob Updated"))
        
        for u in uMany
            @test u.name == "Bob Updated"
        end

        # ------------------------------
        # Teste: Criar registro relacionado (Post)
        # ------------------------------
        userData = Dict("name" => "Thiago", "email" => "thiago@example.com", "cpf" => "00000000000")
        user = create(User, userData)
        postData = Dict("title" => "My First Post", "authorId" => user.id)
        post = create(Post, postData)
        @test post.title == "My First Post"
        @test post.authorId == user.id

        # ------------------------------
        # Teste: Buscar registros relacionados
        # ------------------------------
        @test hasMany(user, Post, "authorId")[1].title == "My First Post"

        # ------------------------------
        # Teste: Deletar vários registros usando query dict
        # ------------------------------
        deleteManyResult = deleteMany(User, Dict("where" => Dict("1" => "1")))
        @test deleteManyResult === true
    end

    @testset "OrionORM Relationships Tests" begin
        userData = Dict("name" => "Thiago", "email" => "thiago@example.com", "cpf" => "00000000000")
        user = create(User, userData)

        foundUser = findFirst(User; query=Dict("where" => Dict("name" => "Thiago")))

        postData = Dict("title" => "My First Post", "authorId" => user.id)
        post = create(Post, postData)

        userWithPosts = findFirst(User; query=Dict("where" => Dict("name" => "Thiago"), "include" => [Post]))
        @test length(userWithPosts["Post"]) == 1
        @test typeof(userWithPosts["Post"][1]) <: Post
        @test userWithPosts["Post"][1].title == "My First Post"
        @test userWithPosts["Post"][1].authorId == user.id

    end

    @testset "OrionORM Pagination Tests" begin
        # Cria registros para paginação
        # Limpa registros anteriores (se necessário)
        deleteMany(User)
        
        # Cria uma lista de 5 usuários com nomes numerados
        usersData = [ Dict("name" => "User $(i)", "email" => "user$(i)@example.com", "cpf" => string(1000 + i)) for i in 1:5 ]
        createdUsers = createMany(User, usersData)
        @test createdUsers == true
        @test length(findMany(User)) == 5  # Verifica se 5 usuários foram criados

        # Teste: Recupera 2 usuários por vez, começando do primeiro
        page1 = findMany(User; query=Dict("limit" => 2, "offset" => 0, "orderBy" => "id"))
        @test length(page1) == 2
        @test page1[1].name == "User 1"
        @test page1[2].name == "User 2"

        # Teste: Recupera os próximos 2 usuários a partir do terceiro
        page2 = findMany(User; query=Dict("limit" => 2, "offset" => 2, "orderBy" => "id"))
        @test length(page2) == 2
        @test page2[1].name == "User 3"
        @test page2[2].name == "User 4"

        # Teste: Recupera os registros restantes
        page3 = findMany(User; query=Dict("limit" => 2, "offset" => 4, "orderBy" => "id"))
        @test length(page3) == 1
        @test page3[1].name == "User 5"
    end
end

using BenchmarkTools
using Random

@testset "OrionORM Bulk Operations & Benchmarks" begin
    # Limpa tabela
    deleteMany(User, Dict("where" => "1=1"))

    # Prepara dados
    N = 100
    user_payloads = [Dict("name" => "BenchUser$(i)",
                          "email" => "bench$(i)@example.com") for i in 1:N]

    # Benchmark de INSERTs em loop sequencial
    t_insert = @elapsed for payload in user_payloads
        create(User, payload)
    end
    @info "100 inserts sequenciais em $(t_insert) segundos"

    # Garante que temos dados
    @test length(findMany(User)) == N

    # Benchmark de SELECTs aleatórios
    t_select = @elapsed for _ in 1:N
        idx = rand(1:N)
        findFirst(User; query=Dict("where" => Dict("email" => "bench$(idx)@example.com")))
    end
    @info "100 selects sequenciais em $(t_select) segundos"

    # Verifica integridade de um select
    sample = findFirst(User; query=Dict("where" => Dict("email" => "bench1@example.com")))
    @test sample !== nothing && sample.email == "bench1@example.com"
end

# # Benchmark de INSERTs utilizando @benchmark macro com criação de dados para insert
# insert_bench = @benchmark begin
#     userData = Dict("name" => "Benchmark User", "email" => randstring(25) * "@example.com", "cpf" => "12345678900")
#     create(User, userData)
# end

# # Benchmark createMany
# insert_many_bench = @benchmark begin
#     userData = [Dict("name" => "Benchmark User $(i)", "email" => "benchmark$(i)@example.com", "cpf" => "12345678900") for i in 1:100]
#     createMany(User, userData)
# end

# # Benchmark de SELECTs utilizando @benchmark macro
# select_bench = @benchmark begin
#     findFirst(User; query=Dict("where" => Dict("email" => "benchmark@example.com")))
# end


# Cleanup: Opcionalmente dropar as tabelas de teste
# dropTable!(conn, "User")
# dropTable!(conn, "Post")

        ```


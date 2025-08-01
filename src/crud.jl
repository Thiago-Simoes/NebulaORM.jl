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
            isa(result, Bool) && return result  # se for um booleano, retorna ele
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
function create(model::DataType, data::Dict{<:AbstractString,<:Any})
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

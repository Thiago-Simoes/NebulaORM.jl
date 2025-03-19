function dropTable!(conn, tableName::String)
    query = "DROP TABLE IF EXISTS " * tableName
    stmt = DBInterface.prepare(conn, query)
    DBInterface.execute(stmt, [])
end


function findMany(model::DataType; query::Dict = Dict())
    query = normalizeQueryDict(query)
    local resolved = resolveModel(model)
    local sqlQuery = buildSqlQuery(resolved, query)
    local conn = dbConnection()
    local stmt = DBInterface.prepare(conn, sqlQuery)
    local df = DBInterface.execute(stmt, []) |> DataFrame
    return [ instantiate(resolved, row) for row in eachrow(df) ]
end

"""
    advancedFindMany(model::DataType; query::AbstractDict = Dict())
Realiza uma consulta avançada no modelo base.
"""
function advancedFindMany(model::DataType; query::AbstractDict = Dict())
    query = normalizeQueryDict(query)
    local resolved = resolveModel(model)
    local sqlQuery = buildSqlQuery(resolved, query)
    local conn = dbConnection()
    local stmt = DBInterface.prepare(conn, sqlQuery)
    local df = DBInterface.execute(stmt, []) |> DataFrame
    local results = [ instantiate(resolved, row) for row in eachrow(df) ]

    if haskey(query, "include")
        local enrichedResults = []
        for rec in results
            local result = serialize(rec)
            for included in query["include"]
                local includedModel = included
                if isa(included, String)
                    includedModel = Base.eval(@__MODULE__, Symbol(included))
                end
                local relationships = getRelationships(resolved)
                for rel in relationships
                    if resolveModel(rel.targetModel) == includedModel
                        local related = nothing
                        if rel.type == :hasMany
                            related = hasMany(rec, rel.field)
                            related = [serialize(r) for r in related]
                        elseif rel.type == :hasOne
                            related = hasOne(rec, rel.field)
                            if related !== nothing
                                related = serialize(related)
                            end
                        elseif rel.type == :belongsTo
                            related = belongsTo(rec, rel.field)
                            if related !== nothing
                                related = serialize(related)
                            end
                        end
                        result[string(includedModel)] = related
                        break
                    end
                end
            end
            push!(enrichedResults, result)
        end
        return enrichedResults
    else
        return results
    end
end


function findFirst(model::DataType; query::Dict = Dict())
    query = normalizeQueryDict(query)
    local resolved = resolveModel(model)
    if !haskey(query, "limit")
        query["limit"] = 1
    end
    local sqlQuery = buildSqlQuery(resolved, query)
    local conn = dbConnection()
    local stmt = DBInterface.prepare(conn, sqlQuery)
    local df = DBInterface.execute(stmt, []) |> DataFrame
    if isempty(df)
        return nothing
    end
    local record = instantiate(resolved, first(df))
    
    # Se "include" estiver presente, enriquece o registro
    if haskey(query, "include")
        local result::Dict{String, Any} = Dict(string(resolved) => record)

        # Para cada modelo incluído, busca os registros relacionados
        for included in query["include"]
            local includedModel = included
            # Se o item incluído for string, converte para tipo
            if isa(included, String)
                includedModel = Base.eval(@__MODULE__, Symbol(included))
            end
            local relationships = getRelationships(resolved)
            for rel in relationships
                if string(resolveModel(rel.targetModel)) == string(includedModel)
                    local related = nothing
                    if rel.type == :hasMany
                        related = hasMany(record, rel.field)
                        # Converte cada registro relacionado para dict
                        related = [r for r in related]
                    elseif rel.type == :hasOne
                        related = hasOne(record, rel.field)
                        if related !== nothing
                            related = related
                        end
                    elseif rel.type == :belongsTo
                        related = belongsTo(record, rel.field)
                        if related !== nothing
                            related = related
                        end
                    end
                    result[string(includedModel)] = related
                    break
                end
            end
        end
        return result
    else
        return record
    end
end

function findFirstOrThrow(model::DataType; query=Dict())
    local rec = findFirst(model; query=query)
    rec === nothing && error("No record found")
    return rec
end

function findUnique(model::DataType, uniqueField, value; query::AbstractDict = Dict())
    query = normalizeQueryDict(query)
    local resolved = resolveModel(model)
    if haskey(query, "where")
        if query["where"] isa Dict
            query["where"][uniqueField] = value
        else
            error("The 'where' field must be a Dict")
        end
    else
        query["where"] = Dict(uniqueField => value)
    end
    if !haskey(query, "limit")
        query["limit"] = 1
    end
    local sqlQuery = buildSqlQuery(resolved, query)
    local conn = dbConnection()
    local stmt = DBInterface.prepare(conn, sqlQuery)
    local df = DBInterface.execute(stmt, []) |> DataFrame
    return isempty(df) ? nothing : instantiate(resolved, first(df))
end

function findUniqueOrThrow(model::DataType, uniqueField, value)
    local rec = findUnique(model, uniqueField, value)
    rec === nothing && error("No unique record found")
    return rec
end

function create(model::DataType, data::Dict)
    local resolved = resolveModel(model)
    local conn = dbConnection()
    local modelFields = Set(String.(fieldnames(resolved)))
    local filtered = Dict(k => v for (k,v) in data if k in modelFields)

    local meta = modelConfig(resolved)
    for col in meta.columns
        if col.type == "VARCHAR(36)" && occursin("UUID", uppercase(join(col.constraints, " ")))
            if !haskey(filtered, col.name)
                filtered[col.name] = generateUuid()
            end
        end
    end

    local cols = join(keys(filtered), ", ")
    local placeholders = join(fill("?", length(keys(filtered))), ", ")
    local vals = collect(values(filtered))
    local queryStr = "INSERT INTO " * meta.name * " (" * cols * ") VALUES (" * placeholders * ")"
    local stmt = DBInterface.prepare(conn, queryStr)
    DBInterface.execute(stmt, vals)

    for col in meta.columns
        if occursin("UNIQUE", uppercase(join(col.constraints, " ")))
            local uniqueValue = filtered[col.name]
            return findFirst(resolved; query = Dict("where" => Dict(col.name => uniqueValue)))
        end
    end

    local id_result = DBInterface.execute(conn, "SELECT LAST_INSERT_ID()")
    local id = first(DataFrame(id_result))[1]
    local pkCol = getPrimaryKeyColumn(resolved)
    if pkCol !== nothing
        return findFirst(resolved; query = Dict("where" => Dict(pkCol.name => id)))
    end

    for col in meta.columns
        if col.type == "VARCHAR(36)" && occursin("UUID", uppercase(join(col.constraints, " ")))
            local uuid = filtered[col.name]
            return findFirst(resolved; query = Dict("where" => Dict(col.name => uuid)))
        end
    end

    error("Não foi possível recuperar o registro inserido.")
end

function update(model::DataType, query::AbstractDict, data::Dict)
    query = normalizeQueryDict(query)
    local resolved = resolveModel(model)
    local conn = dbConnection()
    local modelFields = Set(String.(fieldnames(resolved)))
    local filteredData = Dict(k => v for (k,v) in data if k in modelFields)
    local assignments = join([ "$k = ?" for (k,_) in filteredData ], ", ")
    local vals = collect(values(filteredData))
    
    if !haskey(query, "where")
        error("Query dict must have a 'where' clause for update")
    end
    local whereClause = ""
    local wherePart = query["where"]
    if isa(wherePart, String)
        whereClause = wherePart
    elseif isa(wherePart, Dict)
        whereClause = buildWhereClause(wherePart)
    else
        error("Invalid type for 'where' clause")
    end

    local updateQuery = "UPDATE " * modelConfig(resolved).name * " SET " * assignments * " WHERE " * whereClause
    local stmt = DBInterface.prepare(conn, updateQuery)
    DBInterface.execute(stmt, vals)
    return findFirst(resolved; query=query)
end

function upsert(model::DataType, uniqueField, value, data::Dict)
    local resolved = resolveModel(model)
    local found = findUnique(resolved, uniqueField, value)
    if found === nothing
        return create(resolved, data)
    else
        local queryDict = Dict("where" => Dict(uniqueField => value))
        return update(resolved, queryDict, data)
    end
end

function delete(model::DataType, query::Dict)
    query = normalizeQueryDict(query)
    local resolved = resolveModel(model)
    local conn = dbConnection()
    if !haskey(query, "where")
        error("Query dict must have a 'where' clause for delete")
    end
    local whereClause = ""
    local wherePart = query["where"]
    if isa(wherePart, String)
        whereClause = wherePart
    elseif isa(wherePart, Dict)
        whereClause = buildWhereClause(wherePart)
    else
        error("Invalid type for 'where' clause")
    end

    local deleteQuery = "DELETE FROM " * modelConfig(resolved).name * " WHERE " * whereClause
    local stmt = DBInterface.prepare(conn, deleteQuery)
    DBInterface.execute(stmt, [])
    return true
end

function createMany(model::DataType, dataList::Vector)
    local resolved = resolveModel(model)
    return [ create(resolved, data) for data in dataList ]
end

function createManyAndReturn(model::DataType, dataList::Vector{Dict})
    createMany(model, dataList)
    local resolved = resolveModel(model)
    return findMany(resolved)
end

function updateMany(model::DataType, query, data::Dict)
    local q = normalizeQueryDict(query)
    if !haskey(q, "where")
        error("Query dict must have a 'where' clause for updateMany")
    end
    local wherePart = q["where"]
    local whereClause = ""
    if isa(wherePart, String)
        whereClause = wherePart
    elseif isa(wherePart, Dict)
        whereClause = buildWhereClause(wherePart)
    else
        error("Invalid type for 'where' clause")
    end

    local resolved = resolveModel(model)
    local conn = dbConnection()
    local assignments = join([ "$k = ?" for (k, _) in data ], ", ")
    local vals = collect(values(data))
    local updateQuery = "UPDATE " * modelConfig(resolved).name *
                        " SET " * assignments *
                        " WHERE " * whereClause
    local stmt = DBInterface.prepare(conn, updateQuery)
    DBInterface.execute(stmt, vals)
    return findMany(resolved; query=q)
end

function updateManyAndReturn(model::DataType, query, data::Dict)
    local q = normalizeQueryDict(query)
    updateMany(model, q, data)
    local resolved = resolveModel(model)
    return findMany(resolved; query=q)
end

function deleteMany(model::DataType, query=Dict())
    local q = normalizeQueryDict(query)
    if !haskey(q, "where")
        error("Query dict must have a 'where' clause for deleteMany")
    end
    local wherePart = q["where"]
    local whereClause = ""
    if isa(wherePart, String)
        whereClause = wherePart
    elseif isa(wherePart, Dict)
        whereClause = buildWhereClause(wherePart)
    else
        error("Invalid type for 'where' clause")
    end

    local resolved = resolveModel(model)
    local conn = dbConnection()
    local deleteQuery = "DELETE FROM " * modelConfig(resolved).name *
                        " WHERE " * whereClause
    local stmt = DBInterface.prepare(conn, deleteQuery)
    DBInterface.execute(stmt, [])
    return true
end

# Atualiza registro via método de instância usando query dict (sem aspas extras)
function update(modelInstance)
    local modelType = typeof(modelInstance)
    local pkCol = getPrimaryKeyColumn(modelType)
    pkCol === nothing && error("No primary key defined for model $(modelType)")
    local pkName = pkCol.name
    local id = getfield(modelInstance, Symbol(pkName))
    local query = Dict("where" => Dict(pkName => id))
    local data = Dict{String,Any}()
    for field in fieldnames(modelType)
        data[string(field)] = getfield(modelInstance, field)
    end
    return update(modelType, query, data)
end

# Deleta registro via método de instância usando query dict
function delete(modelInstance)
    local modelType = typeof(modelInstance)
    local pkCol = getPrimaryKeyColumn(modelType)
    pkCol === nothing && error("No primary key defined for model $(modelType)")
    local pkName = pkCol.name
    local id = getfield(modelInstance, Symbol(pkName))
    local query = Dict("where" => Dict(pkName => id))
    return delete(modelType, query)
end

function Base.filter(model::DataType; kwargs...)
    return findMany(model; query=Dict("where" => Dict(kwargs...)))
end
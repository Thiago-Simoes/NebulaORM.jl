# ---------------------------
# Query Builder Inspired by Prisma.io
# ---------------------------
# Função auxiliar para construir a cláusula WHERE a partir de um Dict
function buildWhereClause(whereDict::Dict)
    conditions = String[]
    for (key, val) in whereDict
        if key == "endswith"
            for (col, subStr) in val
                push!(conditions, "$col LIKE '%" * string(subStr) * "'")
            end
        elseif key == "startswith"
            for (col, subStr) in val
                push!(conditions, "$col LIKE '" * string(subStr) * "%'")
            end
        elseif key == "contains"
            for (col, subStr) in val
                push!(conditions, "$col LIKE '%" * string(subStr) * "%'")
            end
        elseif key == "not"
            innerCondition = buildWhereClause(val)
            push!(conditions, "NOT (" * innerCondition * ")")
        elseif key == "in"
            for (col, arr) in val
                valuesStr = join([isa(x, String) ? "'$x'" : string(x) for x in arr], ", ")
                push!(conditions, "$col IN (" * valuesStr * ")")
            end
        else
            if isa(val, String)
                push!(conditions, "$key = '$val'")
            else
                push!(conditions, "$key = " * string(val))
            end
        end
    end
    return join(conditions, " AND ")
end

# Função auxiliar para construir cláusula JOIN com base em um relacionamento
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

# Função principal para queries dinâmicas usando sintaxe inspirada no Prisma.io.
# Suporta chaves: "where", "include", "orderBy", "limit", "offset", "select"
function buildSqlQuery(model::DataType, queryDict::Dict)
    local baseTable = modelConfig(model).name

    # SELECT clause: se o usuário definiu "select", usa-o;
    # senão, se "include" está presente, retorna apenas as colunas da tabela base.
    local selectClause = ""
    if haskey(queryDict, "select")
        local selectFields = queryDict["select"]
        if isa(selectFields, Vector)
            selectClause = join(selectFields, ", ")
        else
            error("select must be a vector of fields")
        end
    else
        if haskey(queryDict, "include")
            selectClause = baseTable * ".*"
        else
            selectClause = "*"
        end
    end

    local query = "SELECT " * selectClause * " FROM " * baseTable


    # WHERE clause
    if haskey(queryDict, "where")
        local whereClause = buildWhereClause(queryDict["where"])
        if whereClause != ""
            query *= " WHERE " * whereClause
        end
    end

    # ORDER BY
    if haskey(queryDict, "orderBy")
        query *= " ORDER BY " * string(queryDict["orderBy"])
    end

    # LIMIT e OFFSET
    if haskey(queryDict, "limit")
        query *= " LIMIT " * string(queryDict["limit"])
        if haskey(queryDict, "offset")
            query *= " OFFSET " * string(queryDict["offset"])
        end
    end

    return query
end


# Função auxiliar para normalizar query dict para Dict{String,Any}
function normalizeQueryDict(query::AbstractDict)
    normalized = Dict{String,Any}()
    for (k, v) in query
        normalized[string(k)] = v
    end
    return normalized
end

using Dates

# Função interna para escapar strings (sem aspas externas)
function sql_escape_raw(value::AbstractString)::String
    clean = replace(value, "'" => "''")                          # Escapa aspas simples
    clean = replace(clean, r"(--|#|;)" => "")                     # Remove comentários e separadores
    clean = replace(clean, r"[\x00-\x1F\x7F]" => "")              # Remove caracteres de controle ASCII
    clean = String(normalize(clean, stripmark=true, compat=true))  # Normaliza Unicode
    return clean
end

# Overloads para sql_escape
sql_escape(x::Nothing) = "NULL"
sql_escape(x::Bool) = x ? "TRUE" : "FALSE"
sql_escape(x::Number) = string(x)
sql_escape(x::Date) = "'$(Dates.format(x, "yyyy-mm-dd"))'"
sql_escape(x::AbstractString) = "'" * sql_escape_raw(x) * "'"

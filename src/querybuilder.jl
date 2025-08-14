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
function _build_where(whereDef, table)::NamedTuple{(:clause,:params)}
    conds  = String[]
    params = Any[]

    if isempty(whereDef)
        return (clause = "1=1", params = params)
    end

    for (k,v) in whereDef
        ks = string(k)

        if ks == "AND" || ks == "OR"
            sub = [_build_where(x, table) for x in v]
            joined = join(["(" * s.clause * ")" for s in sub], " $ks ")
            append!(params, reduce(vcat, [s.params for s in sub], init = Any[]))
            push!(conds, joined)

        elseif ks == "NOT"
            sub = _build_where(v, table)
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
                        push!(conds, "`$table`.`$ks` > ?");   push!(params, val)
                    elseif opos == "gte"
                        push!(conds, "`$table`.`$ks` >= ?");  push!(params, val)
                    elseif opos == "lt"
                        push!(conds, "`$table`.`$ks` < ?");   push!(params, val)
                    elseif opos == "lte"
                        push!(conds, "`$table`.`$ks` <= ?");  push!(params, val)
                    elseif opos == "eq"
                        push!(conds, "`$table`.`$ks` = ?");   push!(params, val)

                    elseif opos == "contains"
                        push!(conds, "`$table`.`$ks` LIKE ?");  push!(params, "%$(val)%")
                    elseif opos == "startsWith"
                        push!(conds, "`$table`.`$ks` LIKE ?");  push!(params, "$(val)%")
                    elseif opos == "endsWith"
                        push!(conds, "`$table`.`$ks` LIKE ?");  push!(params, "%$(val)")

                    elseif opos == "in"
                        ph = join(fill("?", length(val)), ",")
                        push!(conds, "`$table`.`$ks` IN ($ph)"); append!(params, val)
                    elseif opos == "notIn"
                        ph = join(fill("?", length(val)), ",")
                        push!(conds, "`$table`.`$ks` NOT IN ($ph)"); append!(params, val)

                    else
                        error("Operador desconhecido $opos")
                    end
                end

            else
                # caso simples campo = valor
                push!(conds, "`$table`.`$ks` = ?")
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
function qualifyColumn(table, column)
    return "`$table`.`$column`"
end

function qualifyTable(table)
    return "`$table`"
end

# SELECT: qualifica cada coluna
function _build_select(baseTable::String, query)::String
    if haskey(query, "select")
        cols = [qualifyColumn(baseTable, string(c)) for c in query["select"]]
        return join(cols, ", ")
    elseif haskey(query, "include")
        return "$(qualifyTable(baseTable)).*"
    else
        return "*"
    end
end

# === ORDER ===============================================================
function _order_fragment(model::DataType, pair)::String
    (col, dir) = first(pair)
    meta = modelConfig(model)
    allowed = Set(c.name for c in meta.columns)
    scol = string(col)
    scol in allowed || error("orderBy: coluna inválida '$scol'")
    sdir = uppercase(string(dir)) in ("ASC","DESC") ? uppercase(string(dir)) : "ASC"
    return "`$(meta.name)`.`$scol` $sdir"
end

function _build_order(order, model::DataType)::String
    if order isa Dict
        return _order_fragment(model, order)
    elseif order isa Vector
        isempty(order) && error("orderBy: empty vector is not allowed")
        parts = String[]
        for o in order
            o isa Dict || error("orderBy: each element must be a Dict")
            push!(parts, _order_fragment(model, o))
        end
        return join(parts, ", ")
    else
        error("orderBy must be a Dict or a Vector{Dict}; ex: [Dict(\"name\"=>\"asc\"), Dict(\"id\"=>\"desc\")]")
    end
end

# === MAIN BUILDER ========================================================
function buildJoinClause(rootModel::DataType, rel::Relationship)
    # resolve table names
    rootTable     = modelConfig(rootModel).name
    includedModel = resolveModel(rel.targetModel)
    includedName  = nameof(includedModel)

    # ensure model is registered
    if !haskey(modelRegistry, includedName)
        error("Model $includedName not registered")
    end
    includedTable = modelRegistry[includedName].name

    # build join condition based on relationship type
    if rel.type in (:hasMany, :hasOne)
        pkCol = getPrimaryKeyColumn(rootModel)
        isnothing(pkCol) && error("No primary key for model $(nameof(rootModel))")
        joinCondition = string(
            qualifyColumn(rootTable, pkCol.name), 
            " = ", 
            qualifyColumn(includedTable, rel.targetField)
        )
    elseif rel.type == :belongsTo
        parentPk = getPrimaryKeyColumn(includedModel)
        isnothing(parentPk) && error("No primary key for model $includedName")
        joinCondition = string(
            qualifyColumn(includedTable, parentPk.name), 
            " = ", 
            qualifyColumn(rootTable, rel.field)
        )
    else
        error("Unknown relationship type $(rel.type)")
    end

    return (joinType = "INNER", includedModel = includedModel, joinCondition = joinCondition)
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
        w = _build_where(query["where"], baseTable)
        sql    *= " WHERE " * w.clause
        append!(params, w.params)
    end

    # ORDER / LIMIT / OFFSET
    if haskey(query,"orderBy"); sql *= " ORDER BY " * _build_order(query["orderBy"], model) end
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

    tbl   = meta.name
    w = _build_where(query, tbl)
    sql   = "UPDATE $tbl SET " * join(assigns, ", ") * " WHERE " * w.clause
    append!(params, w.params)
    return (sql=sql, params=params)
end
 

"""
    buildDeleteQuery(model::DataType, where::Dict)

Gera:
  sql    = "DELETE FROM table WHERE (…)"; params = [where-params…]
"""
function buildDeleteQuery(model::DataType, query::Dict, forceDelete::Bool=false)
    isempty(query) && !forceDelete && error("Warning: Query must not be empty unless forceDelete is true! Proceed with caution.")
    
    meta   = modelConfig(model)
    tbl   = meta.name
    w      = _build_where(query, tbl)
    sql    = "DELETE FROM " * meta.name * " WHERE " * w.clause
    return (sql=sql, params=w.params)
end


# Mantém compatibilidade com chamadas antigas (sem Dict → retorno igual)
normalizeQuery(q::AbstractDict) = Dict{String,Any}(string(k)=>v for (k,v) in q)
normalizeQuery(q::NamedTuple) = Dict{String,Any}(string(k)=>v for (k,v) in pairs(q))


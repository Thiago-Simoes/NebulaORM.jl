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


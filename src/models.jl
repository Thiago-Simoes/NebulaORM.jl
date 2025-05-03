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
            rev_type::Symbol = rtype == :belongsTo ? :hasMany :
                       rtype == :hasMany   ? :belongsTo : rtype
            rev_rel = Relationship("reverse_$(fld)", modelName, string(fld), rev_type)
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

function instantiate(model::DataType, record)
    meta = modelConfig(model)
    args = []
    for (i, col) in enumerate(meta.columns)
        value = record[i]
        if value === missing
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

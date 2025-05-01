function createTableDefinition(model::Model)
    colDefs = String[]
    keyDefs = String[]
    for col in model.columns
        constraints = copy(col.constraints)
        colType = col.type |> Meta.parse |> eval
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



# ---------------------------
# Macro @Model: Define the model struct and register it
# ---------------------------
"""
        macro Model(modelName, colsExpr)

    Generate a model struct definition and register it in the global model registry.
    
    Exemplo:
    @Model User (
        ("id", NUMBER, PrimaryKey(), AutoIncrement()),
        ("name", VARCHAR(255), NotNull()),
        ("email", VARCHAR(255), NotNull(), Unique())
    )
"""
macro Model(modelName, colsExpr, relationshipsExpr=nothing)
    columnsList = colsExpr.args
    fieldExprs = []
    columnExprs = []
    for col in columnsList
        colName = string(col.args[1])
        colType = string(col.args[2])
        constraintsExpr = esc(col.args[3])
        push!(columnExprs, :( Column($colName, $colType, $constraintsExpr) ))
        juliaType = mapSqlTypeToJulia(colType)
        push!(fieldExprs, :( $(Symbol(colName)) :: $juliaType ))
    end
    local columnsVector = Expr(:vect, columnExprs...)
    structDef = quote
        Base.@kwdef mutable struct $modelName
            $(fieldExprs...)
        end
    end

    registration = quote
        local modelMeta = Model(string($(esc(modelName))), $columnsVector, $(esc(modelName)))
        modelRegistry[nameof($(esc(modelName)))] = modelMeta
        local conn = dbConnection()
        migrate!(conn, modelMeta)
    end

    relRegistration = if !isnothing(relationshipsExpr)
        let relationships = []
            reverseBlocks = [] 
            for rel in relationshipsExpr.args
                field = rel.args[1]
                target_expr = rel.args[2]
                target_field = rel.args[3]
                rel_type = rel.args[4]
                local rt = rel_type isa QuoteNode ? rel_type.value : rel_type
                local original_sym = rt isa Symbol ? rt : Symbol(string(rt))
                local reverse_sym = (original_sym == :belongsTo ? :hasMany :
                                    (original_sym == :hasMany ? :belongsTo : original_sym)) |> QuoteNode
                push!(relationships, 
                    :( Relationship(string($field), $(QuoteNode(target_expr)), string($target_field), $rel_type) ))
                push!(reverseBlocks, :( begin
                    local revRel = Relationship(string("reverse_" * string($field)), $(QuoteNode(modelName)), string($field), Symbol($reverse_sym))
                    local targetModel = resolveModel($(QuoteNode(target_expr)))
                    if !any(r -> r.field == string("reverse_" * string($field)) && r.targetModel == $(QuoteNode(modelName)), 
                            get(relationshipsRegistry, nameof(targetModel), []))
                        if haskey(relationshipsRegistry, nameof(targetModel))
                            push!(relationshipsRegistry[nameof(targetModel)], revRel)
                        else
                            relationshipsRegistry[nameof(targetModel)] = [revRel]
                        end
                    end
                end ))
            end
            quote
                relationshipsRegistry[Symbol(nameof($(esc(modelName))))] = [$((relationships)...)];
                $(reverseBlocks...)
            end
        end
    else
        quote nothing end
    end

    return quote
        $structDef
        $registration
        $relRegistration
    end
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

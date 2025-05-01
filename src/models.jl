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

function register_model(modelName, columnsVector, modelStruct)
    local modelMeta = Model(string(modelName), columnsVector, modelStruct)
    modelRegistry[Symbol(modelName)] = modelMeta
    local conn = dbConnection()
    migrate!(conn, modelMeta)
    return modelMeta
end

function get_rel_property(rel, i)
    if rel isa Expr
        return rel.args[i]
    elseif rel isa Tuple
        return rel[i]
    else
        error("Unsupported relationship type")
    end
end

function convert_target_model(target_expr)
    if target_expr isa String
        return Symbol(target_expr)
    elseif target_expr isa Expr && target_expr.head == :string
        return Symbol(eval(target_expr))
    elseif target_expr isa Symbol || target_expr isa DataType || target_expr isa QuoteNode
        return target_expr
    else
        error("Unsupported type for target_model: $(typeof(target_expr))")
    end
end

function register_relationships(modelName, relationshipsExpr)
    let relationships = []
        reverseBlocks = []
        # Usar relationshipsExpr diretamente, pois agora pode ser um vetor de Tuples ou Exprs
        for rel in relationshipsExpr
            field = get_rel_property(rel, 1)
            target_expr = get_rel_property(rel, 2)
            target_field = get_rel_property(rel, 3)
            rel_type = get_rel_property(rel, 4)
            rt = rel_type isa QuoteNode ? rel_type.value : rel_type
            original_sym = rt isa Symbol ? rt : Symbol(string(rt))
            reverse_sym = original_sym == :belongsTo ? :hasMany :
                          (original_sym == :hasMany ? :belongsTo : original_sym)
            # Converter target_expr explicitamente
            target_model = convert_target_model(target_expr)
            # Criar objeto Relationship diretamente usando target_model (relação direta)
            push!(relationships, Relationship(string(field),
                                                target_model,
                                                string(target_field),
                                                rel_type))
            # Captura target_model em tm para uso no bloco reverso
            tm = target_model
            push!(reverseBlocks, :( begin
                    local revRel = Relationship(string("reverse_" * string($field)),
                                                resolveModel(Symbol($modelName)),
                                                string($field),
                                                Symbol($reverse_sym))
                    local targetModel = resolveModel(Symbol($tm))
                    if !any(r -> r.field == string("reverse_" * string($field)) && r.targetModel == resolveModel(Symbol($modelName)),
                                get(relationshipsRegistry, nameof(targetModel), []))
                        if haskey(relationshipsRegistry, nameof(targetModel))
                            push!(relationshipsRegistry[nameof(targetModel)], revRel)
                        else
                            relationshipsRegistry[nameof(targetModel)] = [revRel]
                        end
                    end
            end))
        end
        relationshipsRegistry[Symbol(modelName)] = relationships
        for block in reverseBlocks
            eval(block)
        end
    end
    return nothing
end

# ---------------------------
# Macro @Model: Define the model struct and metadata
# ---------------------------
"""
        macro Model(modelName, colsExpr)

    Generate a model struct definition and metadata for later registration.
    
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
    if __ORM_INITIALIZED__
        register_orm()
    end
    quote
        $structDef
        __ORM_MODELS__[Symbol(string($(esc(modelName))))] = ($columnsVector, $(relationshipsExpr === nothing ? nothing : esc(relationshipsExpr)))
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

# ---------------------------
# ORM Initialization
# ---------------------------
function register_orm()
    for (model_sym, (columnsVector, relationshipsExpr)) in __ORM_MODELS__
        # Registre o modelo e migre (efeitos colaterais) – funções register_model e register_relationships podem ser invocadas aqui.
        _ = register_model(string(model_sym), columnsVector, Base.eval(Main, model_sym))
        if relationshipsExpr !== nothing
            register_relationships(string(model_sym), relationshipsExpr)
        end
    end
    return nothing
end
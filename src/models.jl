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

function table_exists(conn::DBInterface.Connection, table_name::String)::Bool
    df = executeQuery(conn, """
        SELECT COUNT(*) AS cnt
          FROM information_schema.tables
         WHERE table_schema = DATABASE()
           AND table_name = ?""", [table_name]; useTransaction=false)
    return df.cnt[1] > 0
end

function index_exists(conn::DBInterface.Connection, table_name::String, index_name::String)::Bool
    df = executeQuery(conn, """
        SELECT COUNT(*) AS cnt
          FROM information_schema.statistics
         WHERE table_schema = DATABASE()
           AND table_name = ?
           AND index_name = ?""", [table_name, index_name]; useTransaction=false)
    return df.cnt[1] > 0
end

function constraint_exists(conn::DBInterface.Connection, table_name::String, constraint_name::String)::Bool
    df = executeQuery(conn, """
        SELECT COUNT(*) AS cnt
          FROM information_schema.table_constraints
         WHERE constraint_schema = DATABASE()
           AND table_name = ?
           AND constraint_name = ?""", [table_name, constraint_name]; useTransaction=false)
    return df.cnt[1] > 0
end

# --- Migração idempotente de esquema, índices e FKs ---
function migrate!(conn::DBInterface.Connection, meta::Model)
    tbl = meta.name
    if !table_exists(conn, tbl)
        schema = createTableDefinition(meta)
        executeQuery(conn, "CREATE TABLE $tbl ($schema)", [];
                     useTransaction=false)
    end

    for cols in get(indexesRegistry, Symbol(tbl), [])
        idx_name = "idx_$(tbl)_$(join(cols, "_"))"
        if !index_exists(conn, tbl, idx_name)
            sql = "CREATE INDEX `$idx_name` ON `$tbl` (`$(join(cols, "`, `"))`)"
            executeQuery(conn, sql, [];
                         useTransaction=false)
        end
    end

    # 3) Foreign keys (relacionamentos)
    for rel in get(relationshipsRegistry, Symbol(tbl), Relationship[])
        fk_name = "fk_$(tbl)_$(rel.field)"
        if !constraint_exists(conn, tbl, fk_name)
            sql = nothing
            if rel.type == :belongsTo
                ref_tbl = modelConfig(resolveModel(rel.targetModel)).name
                sql = "ALTER TABLE `$tbl` ADD CONSTRAINT `$fk_name` FOREIGN KEY (`$(rel.field)`) REFERENCES `$ref_tbl`(`$(rel.targetField)`) ON DELETE CASCADE ON UPDATE CASCADE"
            else
                tgt = modelConfig(resolveModel(rel.targetModel)).name
                sql = "ALTER TABLE `$tgt` ADD CONSTRAINT `$fk_name` FOREIGN KEY (`$(rel.targetField)`) REFERENCES `$tbl`(`$(rel.field)`) ON DELETE CASCADE ON UPDATE CASCADE"
            end
            executeQuery(conn, sql, [];
                         useTransaction=false)
        end
    end
end

"""
    Model(modelName::Symbol,
          columnsDef::Vector{<:Tuple{String,String,Vector{<:Any}}},
          relationshipsDef::Vector{<:Tuple{Symbol,Symbol,Symbol,Symbol}} = [],
          indexesDef::Vector{Vector{String}} = [] )

Define um modelo em runtime, criando o `struct`, registrando no `modelRegistry`,
registrando relacionamentos e índices em registries, e executando migração idempotente.
"""
function Model(modelName::Symbol,
               columnsDef::Vector,
               relationshipsDef::Vector = [],
               indexesDef::Vector{<:Vector} = Vector{Vector{String}}())

    # 1) Monta campos do struct com tipos Julia
    field_exprs = Expr[]
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
    @eval Main $struct_expr

    # 3) Cria meta e registra no modelRegistry
    columns_vec = [ Column(name, sql_type, constraints) for (name, sql_type, constraints) in columnsDef ]
    meta = Model(string(modelName), columns_vec, getfield(Main, modelName))
    modelRegistry[Symbol(modelName)] = meta

    # 4) Registra relacionamentos e índices
    if !isempty(relationshipsDef)
        rel_objs = Relationship[]
        for (fld, tgt, tgtfld, rtype) in relationshipsDef
            push!(rel_objs, Relationship(string(fld), Symbol(tgt), string(tgtfld), rtype))
        end
        relationshipsRegistry[Symbol(modelName)] = rel_objs

        # Create a reverse relationship for belongsTo
        for rel in rel_objs
            if rel.type == :belongsTo
                parentModel = resolveModel(rel.targetModel)
                parentName = nameof(parentModel)
                revRel = Relationship(rel.targetField, Symbol(modelName), rel.field, :hasMany)
                if haskey(relationshipsRegistry, Symbol(parentName))
                    push!(relationshipsRegistry[Symbol(parentName)], revRel)
                else
                    relationshipsRegistry[Symbol(parentName)] = [revRel]
                end
            end
        end
    end
    indexesRegistry[Symbol(modelName)] = indexesDef

    # 5) Executa migração idempotente (tabela + índices + FKs)
    conn = dbConnection()
    try
        migrate!(conn, meta)
    finally
        releaseConnection(conn)
    end

    return getfield(Main, modelName)
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
        error("Invalid reference: $modelRef")
    end
end

# ---------------------------
# Helpers
# ---------------------------
function modelConfig(model::DataType)
    key = nameof(model)
    if haskey(modelRegistry, key)
        return modelRegistry[key]
    else
        throw(ModelNotRegisteredError(key))
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
            jt = mapSqlTypeToJulia(col.type)
            push!(args, jt === Int ? 0 :
                        jt === Float64 ? 0.0 :
                        jt === String ? "" :
                        jt === Dates.Date ? Date(0) :
                        jt === Dates.DateTime ? DateTime(0) :
                        nothing)
        else
            push!(args, value)
        end        
    end
    return model(args...)
end


function resetORM!()
    if @isdefined modelRegistry;           empty!(modelRegistry);           end
    if @isdefined relationshipsRegistry;   empty!(relationshipsRegistry);   end
    if @isdefined indexesRegistry;         empty!(indexesRegistry);         end
    if @isdefined __ORM_MODELS__;          empty!(__ORM_MODELS__);          end
end

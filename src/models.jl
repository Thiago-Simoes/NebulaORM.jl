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

function unique_constraint_exists(conn::DBInterface.Connection, table_name::String, constraint_name::String)::Bool
    df = executeQuery(conn, """
        SELECT COUNT(*) AS cnt
          FROM information_schema.table_constraints
         WHERE constraint_schema = DATABASE()
           AND table_name        = ?
           AND constraint_name   = ?
           AND constraint_type   = 'UNIQUE'""", [table_name, constraint_name]; useTransaction=false)
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

function _index_cols_sql(tbl::String, idx::Index)
    parts = String[]
    for c in idx.columns
        if haskey(idx.lengths, c)
            push!(parts, "`$c`($(idx.lengths[c]))")
        else
            push!(parts, "`$c`")
        end
    end
    return join(parts, ", ")
end


# --- Migração idempotente de esquema, índices e FKs ---
function migrate!(conn::DBInterface.Connection, meta::Model)
    tbl = meta.name
    if !table_exists(conn, tbl)
        schema = createTableDefinition(meta)
        executeQuery(conn, "CREATE TABLE $tbl ($schema)", [];
                     useTransaction=false)
    end

    idxdefs = get(indexesRegistry, Symbol(tbl), Any[])

    for raw in idxdefs
        # Back-compat: se vier Vector{String} => índice normal
        idx = if raw isa Vector{String}
            Index(columns=raw)
        elseif raw isa Dict
            # esperado: Dict("columns"=>["a","b"], "unique"=>true, "name"=>"uq_x", "lengths"=>Dict("a"=>191))
            cols    = Vector{String}(raw["columns"])
            uniq    = get(raw, "unique", false)
            iname   = get(raw, "name", nothing)
            ilength = haskey(raw, "lengths") ? Dict{String,Int}(raw["lengths"]) : Dict{String,Int}()
            Index(name=iname, columns=cols, unique=uniq, lengths=ilength)
        elseif raw isa Index
            raw
        else
            error("Unsupported index def: $(typeof(raw))")
        end

        # nome padrão determinístico
        base = idx.unique ? "uq" : "idx"
        iname = isnothing(idx.name) ? "$(base)_$(tbl)_$(join(idx.columns, "_"))" : idx.name

        if idx.unique
            # criar como CONSTRAINT UNIQUE (idempotente via information_schema.table_constraints)
            if !unique_constraint_exists(conn, tbl, iname)
                cols_sql = _index_cols_sql(tbl, idx)
                sql = "ALTER TABLE `$tbl` ADD CONSTRAINT `$iname` UNIQUE ($cols_sql)"
                executeQuery(conn, sql, []; useTransaction=false)
            end
        else
            # índice normal (idempotente via information_schema.statistics)
            if !index_exists(conn, tbl, iname)
                cols_sql = _index_cols_sql(tbl, idx)
                sql = "CREATE INDEX `$iname` ON `$tbl` ($cols_sql)"
                executeQuery(conn, sql, []; useTransaction=false)
            end
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
               indexesDef::Vector = Vector{Any}())

    # 1) Monta campos do struct com tipos Julia
    field_exprs = Expr[]
    for col_def in columnsDef
        if length(col_def) == 2
            col_def = (col_def..., Vector{Any}()) 
        end
        (col_name, sql_type, _) = col_def
        julia_ty = mapSqlTypeToJulia(sql_type)
        push!(field_exprs, :( $(Symbol(col_name))::$(julia_ty) ))
    end

    struct_expr = quote
        Base.@kwdef mutable struct $(modelName)
            $(field_exprs...)
        end
    end
    @eval Main $struct_expr

    columns_vec = []

    for col_def in columnsDef
        if length(col_def) == 2
            col_def = (col_def..., Vector{Any}()) 
        end
        (col_name, sql_type, constraints) = col_def
        julia_ty = mapSqlTypeToJulia(sql_type)
        push!(columns_vec, Column(string(col_name), sql_type, constraints))
    end
    meta = Model(string(modelName), columns_vec, getfield(Main, modelName))
    modelRegistry[Symbol(modelName)] = meta

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

module ORM

using DBInterface
using MySQL
using UUIDs
using DotEnv
using DataFrames
using Dates

export dbConnection, createTableDefinition, migrate!, dropTable!,
       @Model, generateUuid,
       findMany, findFirst, findFirstOrThrow, findUnique, findUniqueOrThrow,
       create, update, upsert, delete, createMany, createManyAndReturn,
       updateMany, updateManyAndReturn, deleteMany, hasMany, belongsTo, hasOne,
       VARCHAR, TEXT, NUMBER, DOUBLE, FLOAT, UUID, @PrimaryKey, @AutoIncrement, @NotNull, @Unique

# Pre-defined SQL type constructors
const VARCHAR    = size -> "VARCHAR($(size))"
const TEXT       = "TEXT"
const NUMBER     = "INTEGER"
const DOUBLE     = "DOUBLE"
const FLOAT      = "FLOAT"
const UUID       = "VARCHAR(36)"
const DATE       = "DATE"
const TIMESTAMP  = "TIMESTAMP"
const JSON       = "JSON"

# ---------------------------
# Estruturas Básicas
# ---------------------------
Base.@kwdef mutable struct Column
    name::String
    type::String
    constraints::Vector{String} = String[]
end

Base.@kwdef mutable struct Model
    name::String
    columns::Vector{Column}
    modelType::DataType
end

Base.@kwdef mutable struct Relationship
    field::String
    targetModel::Union{DataType, Symbol, QuoteNode}
    targetField::String
    type::Symbol  # :hasOne, :hasMany, :belongsTo
end

# Global registry para associar os metadados do modelo (usando o nome do modelo como chave)
const modelRegistry = Dict{Symbol, Model}()

# Registrador de relações também indexado pelo nome do modelo
const relationshipsRegistry = Dict{Symbol, Vector{Relationship}}()

# ---------------------------
# Helper: Mapear tipo SQL para tipo Julia
# ---------------------------
function mapSqlTypeToJulia(sqlType::String)
    sqlType = uppercase(sqlType)
    if sqlType == "INTEGER"
        return :Int
    elseif sqlType in ["FLOAT", "DOUBLE"]
        return :Float64
    elseif sqlType == "TEXT"
        return :String
    elseif sqlType == "TIMESTAMP"
        return :DateTime
    elseif sqlType == "JSON"
        return :String
    elseif sqlType == "UUID"
        return :String
    else
        return :Any
    end
end

# ---------------------------
# Macros para Restrições
# ---------------------------
macro PrimaryKey() 
    :( "PRIMARY KEY" )
end

macro AutoIncrement()
    :( "AUTO_INCREMENT" )
end

macro NotNull()
    :( "NOT NULL" )
end

macro Unique()
    :( "UNIQUE" )
end

# ---------------------------
# Conexão com o Banco de Dados
# ---------------------------
function dbConnection()
    DotEnv.load!()
    dbHost     = ENV["DB_HOST"]
    dbUser     = ENV["DB_USER"]
    dbPassword = ENV["DB_PASSWORD"]
    dbName     = ENV["DB_NAME"]
    dbPort     = parse(Int, string(ENV["DB_PORT"]))
    return DBInterface.connect(MySQL.Connection, dbHost, dbUser, dbPassword, db=dbName, port=dbPort)
end

# ---------------------------
# Criação e Migração da Tabela
# ---------------------------
function createTableDefinition(model::Model)
    colDefs = String[]
    keyDefs = String[]
    for col in model.columns
        constraints = copy(col.constraints)
        if occursin("TEXT", col.type) && "UNIQUE" in constraints
            deleteat!(constraints, findfirst(==("UNIQUE"), constraints))
            push!(keyDefs, "UNIQUE KEY (`$(col.name)`(191))")
        end
        push!(colDefs, "$(col.name) $(col.type) $(join(constraints, " "))")
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

function dropTable!(conn, tableName::String)
    query = "DROP TABLE IF EXISTS " * tableName
    stmt = DBInterface.prepare(conn, query)
    DBInterface.execute(stmt, [])
end

# ---------------------------
# Macro @Model: Define o struct do modelo e registra os metadados
# ---------------------------
"""
        macro Model(modelName, colsExpr)

    Gera a definição de um struct e o bloco de registro para o modelo.
    
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
            for rel in relationshipsExpr.args
                field = rel.args[1]
                target_expr = rel.args[2]
                target_field = rel.args[3]
                rel_type = rel.args[4]
                push!(relationships, :( Relationship(string($field), $(QuoteNode(target_expr)), string($target_field), $rel_type) ))
            end
            quote
                relationshipsRegistry[nameof($(esc(modelName)))] = [$((relationships)...)];
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

function getLastInsertId(conn)
    result = DBInterface.execute(conn, "SELECT LAST_INSERT_ID() as id")
    row = first(result) |> DataFrame
    return row[1, :id]
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
# Relationship Helper Functions
# ---------------------------
# Versão registrada (usando metadados)
function hasMany(parentInstance, relationName)
    parentType = typeof(parentInstance)
    relationships = getRelationships(parentType)
    for rel in relationships
        if rel.field == relationName && rel.type == :hasMany
            pkCol = getPrimaryKeyColumn(parentType)
            if pkCol === nothing
                error("No primary key defined for model $(parentType)")
            end
            parentValue = getfield(parentInstance, Symbol(pkCol.name))
            return findMany(resolveModel(rel.targetModel); query=Dict("where" => Dict(rel.targetField => parentValue)))
        end
    end
    error("No hasMany relationship found with name $relationName for model $(parentType)")
end

# Overload para hasMany com 3 parâmetros
function hasMany(parentInstance, relatedModel::DataType, foreignKey::String)
    local parentType = typeof(parentInstance)
    local pkCol = getPrimaryKeyColumn(parentType)
    if pkCol === nothing
        error("No primary key defined for model $(parentType)")
    end
    local parentValue = getfield(parentInstance, Symbol(pkCol.name))
    return findMany(relatedModel; query=Dict("where" => Dict(foreignKey => parentValue)))
end

# Versão registrada para belongsTo
function belongsTo(childInstance, relationName)
    childType = typeof(childInstance)
    relationships = getRelationships(childType)
    for rel in relationships
        if rel.field == relationName && rel.type == :belongsTo
            childFKValue = getfield(childInstance, Symbol(rel.field))
            return findFirst(resolveModel(rel.targetModel); query=Dict("where" => Dict(rel.targetField => childFKValue)))
        end
    end
    error("No belongsTo relationship found with name $relationName for model $(childType)")
end

# Overload para belongsTo com 3 parâmetros
function belongsTo(childInstance, relatedModel::DataType, foreignKey::String)
    local childValue = getfield(childInstance, Symbol(foreignKey))
    local pk = getPrimaryKeyColumn(relatedModel)
    if pk === nothing
        error("No primary key defined for model $(relatedModel)")
    end
    return findFirst(relatedModel; query=Dict("where" => Dict(pk.name => childValue)))
end

# Versão registrada para hasOne
function hasOne(parentInstance, relationName)
    parentType = typeof(parentInstance)
    relationships = getRelationships(parentType)
    for rel in relationships
        if rel.field == relationName && rel.type == :hasOne
            pkCol = getPrimaryKeyColumn(parentType)
            if pkCol === nothing
                error("No primary key defined for model $(parentType)")
            end
            local parentValue = getfield(parentInstance, Symbol(pkCol.name))
            return findFirst(resolveModel(rel.targetModel); query=Dict("where" => Dict(rel.targetField => parentValue)))
        end
    end
    error("No hasOne relationship found with name $relationName for model $(parentType)")
end

# Overload para hasOne com 3 parâmetros
function hasOne(parentInstance, relatedModel::DataType, foreignKey::String)
    local parentType = typeof(parentInstance)
    local pkCol = getPrimaryKeyColumn(parentType)
    if pkCol === nothing
        error("No primary key defined for model $(parentType)")
    end
    local parentValue = getfield(parentInstance, Symbol(pkCol.name))
    return findFirst(relatedModel; query=Dict("where" => Dict(foreignKey => parentValue)))
end

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
            # for includedModel in queryDict["include"]
            #     local relationships = getRelationships(model)
            #     for rel in relationships
            #         if string(resolveModel(rel.targetModel)) == string(includedModel)
            #             selectClause *= ", " * String(Symbol(rel.targetModel)) * ".*"
            #             break
            #         end
            #     end
            # end
        else
            selectClause = "*"
        end
    end

    local query = "SELECT " * selectClause * " FROM " * baseTable

    # JOIN handling via "include": para cada modelo incluído, procura um relacionamento registrado
    # if haskey(queryDict, "include")
    #     local includeArray = queryDict["include"]
    #     for includedModel in includeArray
    #         local relationships = getRelationships(model)
    #         local found = false
    #         for rel in relationships
    #             if string(resolveModel(rel.targetModel)) == string(includedModel)
    #                 # Obter o join spec (ex: ("INNER", Post, "User.id = Post.authorId"))
    #                 local joinSpec = buildJoinClause(model, rel)
    #                 if joinSpec !== nothing
    #                     joinType, joinModel, onCondition = joinSpec
    #                     local joinTable = String(Symbol(joinModel))
    #                     query *= " " * joinType * " JOIN " * joinTable * " ON " * onCondition
    #                     found = true
    #                     break
    #                 end
    #             end
    #         end
    #         # Opcional: se nenhum relacionamento for encontrado, pode emitir um aviso.
    #     end
    # end

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

function serialize(instance)
    local d = Dict{String,Any}()
    for field in fieldnames(typeof(instance))
        d[string(field)] = getfield(instance, field)
    end
    return d
end

# Função auxiliar para normalizar query dict para Dict{String,Any}
function normalizeQueryDict(query::AbstractDict)
    normalized = Dict{String,Any}()
    for (k, v) in query
        normalized[string(k)] = v
    end
    return normalized
end

# ---------------------------
# Funções CRUD
# ---------------------------
dbConn() = dbConnection()

function findMany(model::DataType; query::Dict = Dict())
    query = normalizeQueryDict(query)
    local resolved = resolveModel(model)
    local sqlQuery = buildSqlQuery(resolved, query)
    local conn = dbConn()
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
    local conn = dbConn()
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
    local conn = dbConn()
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
                        related = [serialize(r) for r in related]
                    elseif rel.type == :hasOne
                        related = hasOne(record, rel.field)
                        if related !== nothing
                            related = serialize(related)
                        end
                    elseif rel.type == :belongsTo
                        related = belongsTo(record, rel.field)
                        if related !== nothing
                            related = serialize(related)
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
    local conn = dbConn()
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
    local conn = dbConn()
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
    local conn = dbConn()
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
    local conn = dbConn()
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
    local conn = dbConn()
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
    local conn = dbConn()
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

# ---------------------------
# Utility: Gerar UUID
# ---------------------------
function generateUuid()
    return string(uuid4())
end

end  # module ORM

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


# Global registry para associar os metadados do modelo
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
    # Use interpolation for table name and schema; no value binding for identifiers.
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

    # Arguments
    - `modelName`: name of the model
    - `colsExpr`: tuple of tuples with column definitions

    # Return with explanation
    Generates a struct definition and a registration block for the model.
    
    # Example
    julia> @Model User (
        ("id", NUMBER, PrimaryKey(), AutoIncrement()),
        ("name", VARCHAR(255), NotNull()),
        ("email", VARCHAR(255), NotNull(), Unique())
    )

    # Output
    Base.@kwdef mutable struct User
        id::Int
        name::String
        email::String
    end
"""
macro Model(modelName, colsExpr, relationshipsExpr=nothing)
    # Processa as colunas como antes
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
        # Tenta obter o tipo no módulo atual; ajuste se estiver em outro módulo
        return Base.eval(@__MODULE__, modelRef)
    elseif modelRef isa DataType
        return modelRef
    else
        error("Referência de modelo inválida: $modelRef")
    end
end


# ---------------------------
# Helper: Retorna metadados do modelo a partir do registry
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


# ---------------------------
# Helper: Obtém o último ID inserido via query
# ---------------------------

function getLastInsertId(conn)
    result = DBInterface.execute(conn, "SELECT LAST_INSERT_ID() as id")
    row = first(result) |> DataFrame
    return row[1, :id]
end

# ---------------------------
# Helper: Obtém a coluna de chave primária do modelo
# ---------------------------
function getPrimaryKeyColumn(model::DataType)
    meta = modelConfig(model)
    for col in meta.columns
        if occursin("PRIMARY KEY", uppercase(join(col.constraints, " ")))
            return col
        end
    end
    return nothing
end

# ---------------------------
# Instanciar um modelo a partir de um Dict (utilizando keyword arguments)
# ---------------------------
function convertRowToDict(row, model::DataType)
    meta = modelConfig(model)
    d = Dict{String,Any}()
    for (i, col) in enumerate(meta.columns)
        d[col.name] = row[i]
    end
    return d
end

# Atualiza a função instantiate para usar a conversão acima
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
# Retrieves all related records in a "hasMany" relationship
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
            filterStr = "$(rel.targetField) = " * (isa(parentValue, String) ? "'$parentValue'" : string(parentValue))
            return findMany(resolveModel(rel.targetModel); filter=filterStr)
        end
    end
    error("No hasMany relationship found with name $relationName for model $(parentType)")
end

function hasMany(parentInstance, relatedModel::DataType, foreignKey::String)
    local parentType = typeof(parentInstance)
    local pkCol = getPrimaryKeyColumn(parentType)
    if pkCol === nothing
        error("No primary key defined for model $(parentType)")
    end
    local parentValue = getfield(parentInstance, Symbol(pkCol.name))
    # Cria o query dict usando o foreignKey para filtrar os registros do modelo relacionado
    return findMany(relatedModel; query=Dict("where" => Dict(foreignKey => parentValue)))
end


# Retrieves the parent record in a "belongsTo" relationship
function belongsTo(childInstance, relationName)
    childType = typeof(childInstance)
    relationships = getRelationships(childType)
    for rel in relationships
        if rel.field == relationName && rel.type == :belongsTo
            childFKValue = getfield(childInstance, Symbol(rel.field))
            return findUnique(resolveModel(rel.targetModel), rel.targetField, childFKValue)
        end
    end
    error("No belongsTo relationship found with name $relationName for model $(childType)")
end

function belongsTo(childInstance, relatedModel::DataType, foreignKey::String)
    # Obtém o valor da chave estrangeira no registro filho
    local childValue = getfield(childInstance, Symbol(foreignKey))
    # Busca a chave primária do modelo relacionado
    local pk = getPrimaryKeyColumn(relatedModel)
    if pk === nothing
        error("No primary key defined for model $(relatedModel)")
    end
    # Usa o valor da chave estrangeira para buscar o registro pai
    return findUnique(relatedModel, pk.name, childValue)
end


# Retrieves the single related record in a "hasOne" relationship
function hasOne(parentInstance, relationName)
    parentType = typeof(parentInstance)
    relationships = getRelationships(parentType)
    for rel in relationships
        if rel.field == relationName && rel.type == :hasOne
            pkCol = getPrimaryKeyColumn(parentType)
            if pkCol === nothing
                error("No primary key defined for model $(parentType)")
            end
            parentValue = getfield(parentInstance, Symbol(pkCol.name))
            filterStr = "$(rel.targetField) = " * (isa(parentValue, String) ? "'$parentValue'" : string(parentValue))
            return findFirst(resolveModel(rel.targetModel); filter=filterStr)
        end
    end
    error("No hasOne relationship found with name $relationName for model $(parentType)")
end

function hasOne(parentInstance, relatedModel::DataType, foreignKey::String)
    # Obtém a chave primária do registro pai
    local parentType = typeof(parentInstance)
    local pkCol = getPrimaryKeyColumn(parentType)
    if pkCol === nothing
        error("No primary key defined for model $(parentType)")
    end
    local parentValue = getfield(parentInstance, Symbol(pkCol.name))
    # Busca o registro relacionado que tem o foreignKey igual ao valor da chave primária do pai
    return findFirst(relatedModel; query=Dict("where" => Dict(foreignKey => parentValue)))
end


# ---------------------------
# Query Builder Inspired by Prisma.io
# ---------------------------
# Helper function to build the WHERE clause from a Dict
function buildWhereClause(whereDict::Dict)
    conditions = String[]
    for (key, val) in whereDict
        if key == "endswith"
            # For each column, create condition with LIKE '%value'
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
            # 'in' expects a Dict mapping a column to an array of values
            for (col, arr) in val
                valuesStr = join([isa(x, String) ? "'$x'" : string(x) for x in arr], ", ")
                push!(conditions, "$col IN (" * valuesStr * ")")
            end
        else
            # Direct equality
            if isa(val, String)
                push!(conditions, "$key = '$val'")
            else
                push!(conditions, "$key = " * string(val))
            end
        end
    end
    return join(conditions, " AND ")
end

# Helper function to build JOIN clause based on a relationship
function buildJoinClause(rootModel::DataType, rel::Relationship)
    rootTable = modelConfig(rootModel).name
    includedModel = resolveModel(rel.targetModel)
    includedTable = modelConfig(includedModel).name
    if rel.type in (:hasMany, :hasOne)
        pkCol = getPrimaryKeyColumn(rootModel)
        if pkCol === nothing
            error("No primary key for model $(rootModel)")
        end
        joinCondition = "$rootTable." * pkCol.name * " = $includedTable." * rel.targetField
    elseif rel.type == :belongsTo
        parentPk = getPrimaryKeyColumn(includedModel)
        joinCondition = "$includedTable." * parentPk.name * " = $rootTable." * rel.field
    else
        error("Unknown relationship type $(rel.type)")
    end
    return ("INNER", includedModel, joinCondition)
end

# Main function for dynamic queries using a Prisma-like syntax.
# Supports keys: "where", "include", "orderBy", "limit", "offset"
function prismaQuery(model::DataType, queryDict::Dict)
    # Extract query parameters
    whereClause = ""
    orderByClause = ""
    limitClause = ""
    offsetClause = ""
    joinSpecs = []

    if haskey(queryDict, "where")
        whereClause = buildWhereClause(queryDict["where"])
    end

    if haskey(queryDict, "orderBy")
        orderByClause = queryDict["orderBy"]
    end

    if haskey(queryDict, "limit")
        limitClause = "LIMIT " * string(queryDict["limit"])
    end

    if haskey(queryDict, "offset")
        offsetClause = "OFFSET " * string(queryDict["offset"])
    end

    if haskey(queryDict, "include")
        includeArray = queryDict["include"]
        for includedModel in includeArray
            relationships = getRelationships(model)
            found = false
            for rel in relationships
                if resolveModel(rel.targetModel) == includedModel
                    push!(joinSpecs, buildJoinClause(model, rel))
                    found = true
                    break
                end
            end
            # Optionally: warn if relationship not found for the include
        end
    end

    rootTable = modelConfig(model).name
    query = "SELECT * FROM $rootTable"
    for joinSpec in joinSpecs
        joinType, joinModel, onCondition = joinSpec
        joinTable = modelConfig(joinModel).name
        query *= " $(joinType) JOIN $joinTable ON $onCondition"
    end

    if whereClause != ""
        query *= " WHERE $whereClause"
    end
    if orderByClause != ""
        query *= " ORDER BY $orderByClause"
    end
    if limitClause != ""
        query *= " " * limitClause
    end
    if offsetClause != ""
        query *= " " * offsetClause
    end

    conn = dbConn()
    stmt = DBInterface.prepare(conn, query)
    df = DBInterface.execute(stmt, []) |> DataFrame
    results = [ instantiate(model, row) for row in eachrow(df) ]

    # If "include" is specified, enrich results with related records.
    if haskey(queryDict, "include")
        enrichedResults = []
        for rec in results
            enriched = Dict("record" => rec)
            for includedModel in queryDict["include"]
                relationships = getRelationships(model)
                for rel in relationships
                    if resolveModel(rel.targetModel) == includedModel
                        if rel.type == :hasMany
                            enriched[string(includedModel)] = hasMany(rec, rel.field)
                        elseif rel.type == :hasOne
                            enriched[string(includedModel)] = hasOne(rec, rel.field)
                        elseif rel.type == :belongsTo
                            enriched[string(includedModel)] = belongsTo(rec, rel.field)
                        end
                        break
                    end
                end
            end
            push!(enrichedResults, enriched)
        end
        return enrichedResults
    end

    return results
end


# ---------------------------
# Funções CRUD
# ---------------------------
dbConn() = dbConnection()

function buildSqlQuery(model::DataType, queryDict::Dict)
    # Build SELECT clause
    local selectClause = "*"
    if haskey(queryDict, "select")
        local selectFields = queryDict["select"]
        if isa(selectFields, Vector)
            selectClause = join(selectFields, ", ")
        else
            error("select must be a vector of fields")
        end
    end

    local baseTable = modelConfig(model).name
    local query = "SELECT " * selectClause * " FROM " * baseTable

    # Handle JOIN if "include" is specified
    local joinSpecs = []
    if haskey(queryDict, "include")
        local includeArray = queryDict["include"]
        for includedModel in includeArray
            local relationships = getRelationships(model)
            local found = false
            for rel in relationships
                if resolveModel(rel.targetModel) == includedModel
                    push!(joinSpecs, buildJoinClause(model, rel))
                    found = true
                    break
                end
            end
            # Opcional: avisar se não encontrar a relação
        end
        for joinSpec in joinSpecs
            joinType, joinModel, onCondition = joinSpec
            local joinTable = modelConfig(joinModel).name
            query *= " $(joinType) JOIN $joinTable ON $onCondition"
        end
    end

    # Build WHERE clause
    if haskey(queryDict, "where")
        local whereClause = buildWhereClause(queryDict["where"])
        if whereClause != ""
            query *= " WHERE " * whereClause
        end
    end

    # Order By
    if haskey(queryDict, "orderBy")
        query *= " ORDER BY " * string(queryDict["orderBy"])
    end

    # Limit e Offset
    if haskey(queryDict, "limit")
        query *= " LIMIT " * string(queryDict["limit"])
        if haskey(queryDict, "offset")
            query *= " OFFSET " * string(queryDict["offset"])
        end
    end

    return query
end


function normalizeQueryDict(query::AbstractDict)
    normalized = Dict{String,Any}()
    for (k, v) in query
        normalized[string(k)] = v
    end
    return normalized
end


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
    advancedFindMany(model::DataType; 
                     joins=[], 
                     filters="", 
                     orderBy="", 
                     limit::Union{Int,Nothing}=nothing, 
                     offset::Union{Int,Nothing}=nothing)

Realiza uma consulta avançada no modelo base, permitindo definir joins, filtros, ordenação e paginação.

- `joins`: vetor de tuplas no formato `(tipo::Symbol, modelJoin::DataType, condição::String)`.  
  *Exemplo*: `[(:INNER, Post, "User.id = Post.authorId")]`
- `filters`: string com condições adicionais (ex.: `"User.name LIKE '%João%'"`).
- `orderBy`: string definindo a ordenação (ex.: `"User.createdAt DESC"`).
- `limit` e `offset`: para paginação.
"""
function advancedFindMany(model::DataType; query::AbstractDict = Dict())
    query = normalizeQueryDict(query)
    local resolved = resolveModel(model)
    local sqlQuery = buildSqlQuery(resolved, query)
    local conn = dbConn()
    local stmt = DBInterface.prepare(conn, sqlQuery)
    local df = DBInterface.execute(stmt, []) |> DataFrame
    local results = [ instantiate(resolved, row) for row in eachrow(df) ]

    # Se a query incluir "include", enriquece os resultados com os registros relacionados
    if haskey(query, "include")
        local enrichedResults = []
        for rec in results
            local enriched = Dict("record" => rec)
            for includedModel in query["include"]
                local relationships = getRelationships(model)
                for rel in relationships
                    if resolveModel(rel.targetModel) == includedModel
                        if rel.type == :hasMany
                            enriched[string(includedModel)] = hasMany(rec, rel.field)
                        elseif rel.type == :hasOne
                            enriched[string(includedModel)] = hasOne(rec, rel.field)
                        elseif rel.type == :belongsTo
                            enriched[string(includedModel)] = belongsTo(rec, rel.field)
                        end
                        break
                    end
                end
            end
            push!(enrichedResults, enriched)
        end
        return enrichedResults
    end

    return results
end


function findFirst(model::DataType; query::Dict = Dict())
    query = normalizeQueryDict(query)
    local resolved = resolveModel(model)
    # Garante que haja LIMIT 1 na query
    if !haskey(query, "limit")
        query["limit"] = 1
    end
    local sqlQuery = buildSqlQuery(resolved, query)
    local conn = dbConn()
    local stmt = DBInterface.prepare(conn, sqlQuery)
    local res = DBInterface.execute(stmt, []) |> DataFrame
    return isempty(res) ? nothing : instantiate(resolved, first(res))
end

function findFirstOrThrow(model::DataType; filter=filter)
    rec = findFirst(model; filter=filter)
    rec === nothing && error("No record found")
    return rec
end

function findUnique(model::DataType, uniqueField, value; query::AbstractDict = Dict())
    query = normalizeQueryDict(query)
    local resolved = resolveModel(model)
    # Adiciona a condição única ao filtro
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
    local res = DBInterface.execute(stmt, []) |> DataFrame
    return isempty(res) ? nothing : instantiate(resolved, first(res))
end

function findUniqueOrThrow(model::DataType, uniqueField, value)
    rec = findUnique(model, uniqueField, value)
    rec === nothing && error("No unique record found")
    return rec
end

function create(model::DataType, data::Dict)
    local resolved = resolveModel(model)
    local conn = dbConn()
    local modelFields = Set(String.(fieldnames(resolved)))
    local filtered = Dict(k => v for (k,v) in data if k in modelFields)

    meta = modelConfig(resolved)

    # Verificar se há um campo UUID e gerar o UUID se necessário
    for col in meta.columns
        if col.type == "VARCHAR(36)" && occursin("UUID", uppercase(join(col.constraints, " ")))
            if !haskey(filtered, col.name)
                filtered[col.name] = generateUuid()
            end
        end
    end

    cols = join(keys(filtered), ", ")
    placeholders = join(fill("?", length(keys(filtered))), ", ")
    vals = collect(values(filtered))
    query = "INSERT INTO " * meta.name * " (" * cols * ") VALUES (" * placeholders * ")"
    stmt = DBInterface.prepare(conn, query)
    DBInterface.execute(stmt, vals)

    # Se há um campo único definido:
    for col in meta.columns
        if occursin("UNIQUE", uppercase(join(col.constraints, " ")))
            local uniqueValue = filtered[col.name]
            return findFirst(resolved; query = Dict("where" => Dict(col.name => uniqueValue)))
        end
    end

    # Se não houver, use LAST_INSERT_ID:
    local id_result = DBInterface.execute(conn, "SELECT LAST_INSERT_ID()")
    local id = first(DataFrame(id_result))[1]
    local pkCol = getPrimaryKeyColumn(resolved)
    if pkCol !== nothing
        return findFirst(resolved; query = Dict("where" => Dict(pkCol.name => id)))
    end

    # Buscar pelo campo UUID se necessário:
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

# Atualiza vários registros e retorna os registros atualizados
function updateManyAndReturn(model::DataType, query, data::Dict)
    local q = normalizeQueryDict(query)
    updateMany(model, q, data)
    local resolved = resolveModel(model)
    return findMany(resolved; query=q)
end

# Deleta vários registros com base no query dict (que deve conter a cláusula "where")
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

function update(modelInstance)
    modelType = typeof(modelInstance)
    pkCol = getPrimaryKeyColumn(modelType)
    pkCol === nothing && error("No primary key defined for model $(modelType)")
    pkName = pkCol.name
    id = getfield(modelInstance, Symbol(pkName))
    query = Dict("where" => Dict(pkName => (isa(id, String) ? "'$id'" : string(id))))
    data = Dict{String,Any}()
    for field in fieldnames(modelType)
        data[string(field)] = getfield(modelInstance, field)
    end
    return update(modelType, query, data)
end

function delete(modelInstance)
    modelType = typeof(modelInstance)
    pkCol = getPrimaryKeyColumn(modelType)
    pkCol === nothing && error("No primary key defined for model $(modelType)")
    pkName = pkCol.name
    id = getfield(modelInstance, Symbol(pkName))
    query = Dict("where" => Dict(pkName => (isa(id, String) ? "'$id'" : string(id))))

    return delete(modelType, query)
end

function Base.filter(model::DataType; kwargs...)
    local resolved = resolveModel(model)
    local conditions = [ "$k = " * (isa(v, String) ? "'$v'" : string(v)) for (k,v) in kwargs ]
    local filterStr = join(conditions, " AND ")
    return findMany(resolved; filter=filterStr)
end


# ---------------------------
# Utility: Gerar UUID
# ---------------------------
function generateUuid()
    return string(uuid4())
end

end  # module ORM

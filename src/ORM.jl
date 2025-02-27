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
       updateMany, updateManyAndReturn, deleteMany,
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
# Funções CRUD
# ---------------------------
dbConn() = dbConnection()

function findMany(model::DataType; filter=missing)
    local resolved = resolveModel(model)
    query = "SELECT * FROM " * modelConfig(resolved).name *
            (filter === missing ? "" : " WHERE " * filter)
    local conn = dbConn()
    local stmt = DBInterface.prepare(conn, query)
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
function advancedFindMany(model::DataType; 
                          joins=[], 
                          filters="", 
                          orderBy="", 
                          limit::Union{Int,Nothing}=nothing, 
                          offset::Union{Int,Nothing}=nothing)
    local resolved = resolveModel(model)
    local baseTable = modelConfig(resolved).name
    local query = "SELECT * FROM $baseTable"

    # Adicionar cláusulas JOIN
    for joinSpec in joins
        joinType, joinModel, onCondition = joinSpec
        local joinTable = modelConfig(resolveModel(joinModel)).name
        query *= " $(uppercase(String(joinType))) JOIN $joinTable ON $onCondition"
    end

    # Filtros
    if !isempty(filters)
        query *= " WHERE $filters"
    end

    # Ordenação
    if !isempty(orderBy)
        query *= " ORDER BY $orderBy"
    end

    # Limite e Offset
    if limit !== nothing
        query *= " LIMIT $limit"
        if offset !== nothing
            query *= " OFFSET $offset"
        end
    end

    local conn = dbConn()
    local stmt = DBInterface.prepare(conn, query)
    local df = DBInterface.execute(stmt, []) |> DataFrame
    return [ instantiate(resolved, row) for row in eachrow(df) ]
end


function findFirst(model::DataType; filter=missing)
    local resolved = resolveModel(model)
    local conn = dbConn()
    local query = "SELECT * FROM " * modelConfig(resolved).name *
                  (filter === missing ? "" : " WHERE " * filter) * " LIMIT 1"
    local res = DBInterface.execute(conn, query) |> collect
    return isempty(res) ? nothing : instantiate(resolved, first(res))
end

function findFirstOrThrow(model::DataType; filter=filter)
    rec = findFirst(model; filter=filter)
    rec === nothing && error("No record found")
    return rec
end

function findUnique(model::DataType, uniqueField, value)
    local resolved = resolveModel(model)
    local conn = dbConn()
    local tableName = modelConfig(resolved).name
    local query = "SELECT * FROM " * tableName * " WHERE " * uniqueField * " = ? LIMIT 1"
    local stmt = DBInterface.prepare(conn, query)
    local res = DBInterface.execute(stmt, [value]) |> collect
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
            uniqueValue = filtered[col.name]
            return findFirst(resolved; filter = "$(col.name) = " * (isa(uniqueValue, String) ? "'$uniqueValue'" : string(uniqueValue)))
        end
    end

    # Se não houver, use LAST_INSERT_ID:
    id_result = DBInterface.execute(conn, "SELECT LAST_INSERT_ID()")
    id = first(DataFrame(id_result))[1]
    pkCol = getPrimaryKeyColumn(resolved)
    if pkCol !== nothing
        return findFirst(resolved; filter = "$(pkCol.name) = $id")
    end

    # Buscar pelo campo UUID se necessário:
    for col in meta.columns
        if col.type == "VARCHAR(36)" && occursin("UUID", uppercase(join(col.constraints, " ")))
            uuid = filtered[col.name]
            return findFirst(resolved; filter = "$(col.name) = '$uuid'")
        end
    end

    error("Não foi possível recuperar o registro inserido.")
end

function update(model::DataType, filter::String, data::Dict)
    local resolved = resolveModel(model)
    local conn = dbConn()
    local modelFields = Set(String.(fieldnames(resolved)))
    local filtered = Dict(k => v for (k,v) in data if k in modelFields)
    local assignments = join([ "$k = ?" for (k,_) in filtered ], ", ")
    local vals = collect(values(filtered))
    local query = "UPDATE " * modelConfig(resolved).name * " SET " * assignments * " WHERE " * filter
    local stmt = DBInterface.prepare(conn, query)
    DBInterface.execute(stmt, vals)
    return findFirst(resolved; filter = filter)
end

function upsert(model::DataType, uniqueField, value, data::Dict)
    local resolved = resolveModel(model)
    local found = findUnique(resolved, uniqueField, value)
    if found === nothing
        return create(resolved, data)
    else
        local f = "$uniqueField = " * (isa(value, String) ? "'$value'" : string(value))
        return update(resolved, f, data)
    end
end

function delete(model::DataType, filter::String)
    local resolved = resolveModel(model)
    local conn = dbConn()
    local query = "DELETE FROM " * modelConfig(resolved).name * " WHERE " * filter
    local stmt = DBInterface.prepare(conn, query)
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

function updateMany(model::DataType, filter::String, data::Dict)
    local resolved = resolveModel(model)
    local conn = dbConn()
    local assignments = join([ "$k = ?" for (k,_) in data ], ", ")
    local vals = collect(values(data))
    local query = "UPDATE " * modelConfig(resolved).name * " SET " * assignments * " WHERE " * filter
    local stmt = DBInterface.prepare(conn, query)
    DBInterface.execute(stmt, vals)
    return findMany(resolved; filter = filter)
end

function updateManyAndReturn(model::DataType, filter::String, data::Dict)
    updateMany(model, filter, data)
    local resolved = resolveModel(model)
    return findMany(resolved; filter = filter)
end

function deleteMany(model::DataType, filter::String)
    local resolved = resolveModel(model)
    local conn = dbConn()
    local query = "DELETE FROM " * modelConfig(resolved).name * " WHERE " * filter
    local stmt = DBInterface.prepare(conn, query)
    DBInterface.execute(stmt, [])
    return true
end

function update(modelInstance)
    modelType = typeof(modelInstance)
    pkCol = getPrimaryKeyColumn(modelType)
    pkCol === nothing && error("No primary key defined for model $(modelType)")
    pkName = pkCol.name
    id = getfield(modelInstance, Symbol(pkName))
    filterStr = "$pkName = " * (isa(id, String) ? "'$id'" : string(id))
    data = Dict{String,Any}()
    for field in fieldnames(modelType)
        data[string(field)] = getfield(modelInstance, field)
    end
    return update(modelType, filterStr, data)
end

function delete(modelInstance)
    modelType = typeof(modelInstance)
    pkCol = getPrimaryKeyColumn(modelType)
    pkCol === nothing && error("No primary key defined for model $(modelType)")
    pkName = pkCol.name
    id = getfield(modelInstance, Symbol(pkName))
    filterStr = "$pkName = " * (isa(id, String) ? "'$id'" : string(id))
    return delete(modelType, filterStr)
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

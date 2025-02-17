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

# Global registry para associar os metadados do modelo
const modelRegistry = Dict{DataType, Model}()

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
macro Model(modelName, colsExpr)
    # Processa as colunas (espera-se uma tupla de tuplas: (nome, tipo, restrições))
    columnsList = colsExpr.args
    fieldExprs = []
    columnExprs = []
    for col in columnsList
        # Obtém o nome e tipo da coluna
        colName = String(strip(col.args[1]))
        colType = String(strip(col.args[2]))
        # Escapa a expressão das restrições
        constraintsExpr = esc(col.args[3])
        # Cria a expressão que instancia Column
        push!(columnExprs, :( Column($colName, $colType, $constraintsExpr) ))
        # Mapeia o tipo SQL para o tipo Julia e define o campo no struct
        juliaType = mapSqlTypeToJulia(colType)
        push!(fieldExprs, :( $(Symbol(colName)) :: $juliaType ))
    end
    # Constrói a expressão de um vetor literal com as colunas
    local columnsVector = Expr(:vect, columnExprs...)
    structDef = quote
        Base.@kwdef mutable struct $modelName
            $(fieldExprs...)
        end
    end
    registration = quote
        local modelMeta = Model(string($(esc(modelName))), $columnsVector, $(esc(modelName)))
        modelRegistry[$(esc(modelName))] = modelMeta
        local conn = dbConnection()
        migrate!(conn, modelMeta)
    end
    return quote
        $structDef
        $registration
    end
end

# ---------------------------
# Helper: Retorna metadados do modelo a partir do registry
# ---------------------------
function modelConfig(model::DataType)
    if haskey(modelRegistry, model)
        return modelRegistry[model]
    else
        error("Model not registered")
    end
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
    conn = dbConn()
    query = "SELECT * FROM " * modelConfig(model).name *
            (filter === missing ? "" : " WHERE " * filter)
    stmt = DBInterface.prepare(conn, query)
    df = DBInterface.execute(stmt, []) |> DataFrame
    return [ instantiate(model, row) for row in eachrow(df) ]
end

function findFirst(model::DataType; filter=missing)
    conn = dbConn()
    query = "SELECT * FROM " * modelConfig(model).name *
            (filter === missing ? "" : " WHERE " * filter) * " LIMIT 1"
    res = DBInterface.execute(conn, query) |> collect
    return isempty(res) ? nothing : instantiate(model, first(res))
end

function findFirstOrThrow(model::DataType; filter=filter)
    rec = findFirst(model; filter=filter)
    rec === nothing && error("No record found")
    return rec
end

function findUnique(model::DataType, uniqueField, value)
    conn = dbConn()
    tableName = modelConfig(model).name
    query = "SELECT * FROM " * tableName * " WHERE " * uniqueField * " = ? LIMIT 1"
    stmt = DBInterface.prepare(conn, query)
    res = DBInterface.execute(stmt, [value]) |> collect
    return isempty(res) ? nothing : instantiate(model, first(res))
end

function findUniqueOrThrow(model::DataType, uniqueField, value)
    rec = findUnique(model, uniqueField, value)
    rec === nothing && error("No unique record found")
    return rec
end

function create(model::DataType, data::Dict)
    conn = dbConn()
    modelFields = Set(String.(fieldnames(model)))
    filtered = Dict(k => v for (k,v) in data if k in modelFields)

    meta = modelConfig(model)

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
            return findFirst(model; filter = "$(col.name) = " * (isa(uniqueValue, String) ? "'$uniqueValue'" : string(uniqueValue)))
        end
    end

    # Se não houver, use LAST_INSERT_ID:
    id_result = DBInterface.execute(conn, "SELECT LAST_INSERT_ID()")
    id = first(DataFrame(id_result))[1]
    pkCol = getPrimaryKeyColumn(model)
    if pkCol !== nothing
        return findFirst(model; filter = "$(pkCol.name) = $id")
    end

    # Buscar pelo campo UUID se necessário:
    for col in meta.columns
        if col.type == "VARCHAR(36)" && occursin("UUID", uppercase(join(col.constraints, " ")))
            uuid = filtered[col.name]
            return findFirst(model; filter = "$(col.name) = '$uuid'")
        end
    end

    error("Não foi possível recuperar o registro inserido.")
end

function update(model::DataType, filter::String, data::Dict)
    conn = dbConn()
    modelFields = Set(String.(fieldnames(model)))
    filtered = Dict(k => v for (k,v) in data if k in modelFields)
    assignments = join([ "$k = ?" for (k,_) in filtered ], ", ")
    vals = collect(values(filtered))
    query = "UPDATE " * modelConfig(model).name * " SET " * assignments * " WHERE " * filter
    stmt = DBInterface.prepare(conn, query)
    DBInterface.execute(stmt, vals)
    return findFirst(model; filter = filter)
end

function upsert(model::DataType, uniqueField, value, data::Dict)
    found = findUnique(model, uniqueField, value)
    if found === nothing
        return create(model, data)
    else
        f = "$uniqueField = " * (isa(value, String) ? "'$value'" : string(value))
        return update(model, f, data)
    end
end

function delete(model::DataType, filter::String)
    conn = dbConn()
    query = "DELETE FROM " * modelConfig(model).name * " WHERE " * filter
    stmt = DBInterface.prepare(conn, query)
    DBInterface.execute(stmt, [])
    return true
end

function createMany(model::DataType, dataList::Vector)
    return [ create(model, data) for data in dataList ]
end

function createManyAndReturn(model::DataType, dataList::Vector{Dict})
    createMany(model, dataList)
    return findMany(model)
end

function updateMany(model::DataType, filter::String, data::Dict)
    conn = dbConn()
    assignments = join([ "$k = ?" for (k,_) in data ], ", ")
    vals = collect(values(data))
    query = "UPDATE " * modelConfig(model).name * " SET " * assignments * " WHERE " * filter
    stmt = DBInterface.prepare(conn, query)
    DBInterface.execute(stmt, vals)
    return findMany(model; filter = filter)
end

function updateManyAndReturn(model::DataType, filter::String, data::Dict)
    updateMany(model, filter, data)
    return findMany(model; filter = filter)
end

function deleteMany(model::DataType, filter::String)
    conn = dbConn()
    query = "DELETE FROM " * modelConfig(model).name * " WHERE " * filter
    stmt = DBInterface.prepare(conn, query)
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
    conditions = [ "$k = " * (isa(v, String) ? "'$v'" : string(v)) for (k,v) in kwargs ]
    filterStr = join(conditions, " AND ")
    return findMany(model; filter=filterStr)
end


# ---------------------------
# Utility: Gerar UUID
# ---------------------------
function generateUuid()
    return string(uuid4())
end

end  # module ORM

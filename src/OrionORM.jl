module OrionORM

using DBInterface
using MySQL
using UUIDs
using DotEnv
using DataFrames
using Dates
using Logging

include("./pool.jl")
include("./dbconnection.jl")
include("./types.jl")
include("./keys.jl")
include("./others.jl")
include("./models.jl")
include("./relationships.jl")
include("./querybuilder.jl")
include("./crud.jl")


# ---------------------------
# Global registry for associating model metadata (using the model name as key)
const modelRegistry = Dict{Symbol, Model}()
const indexesRegistry = Dict{Symbol, Vector}()

# Global registry for associating model relationships (using the model name as key)
const relationshipsRegistry = Dict{Symbol, Vector{Relationship}}()
const __ORM_MODELS__ = Dict{Symbol, Tuple{Any, Any}}()
__ORM_INITIALIZED__ = false

    
# Automatic initialization only if not precompiling
function __init__()
    initLogger()
    global __ORM_INITIALIZED__ = true
end




export dbConnection, createTableDefinition, migrate!, dropTable!,
       Model, generateUuid, executeQuery, releaseConnection,
       findMany, findFirst, findFirstOrThrow, findUnique, findUniqueOrThrow,
       create, update, upsert, delete, createMany, createManyAndReturn,
       updateMany, updateManyAndReturn, deleteMany, hasMany, belongsTo, hasOne,
       VARCHAR, TEXT, NUMBER, DOUBLE, FLOAT, INTEGER, UUID, DATE, TIMESTAMP, JSON, PrimaryKey, AutoIncrement, NotNull, Unique, Default


end  # module ORM

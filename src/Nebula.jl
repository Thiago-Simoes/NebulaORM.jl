module Nebula

using DBInterface
using MySQL
using UUIDs
using DotEnv
using DataFrames
using Dates

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

# Global registry for associating model relationships (using the model name as key)
const relationshipsRegistry = Dict{Symbol, Vector{Relationship}}()



export dbConnection, createTableDefinition, migrate!, dropTable!,
       @Model, generateUuid,
       findMany, findFirst, findFirstOrThrow, findUnique, findUniqueOrThrow,
       create, update, upsert, delete, createMany, createManyAndReturn,
       updateMany, updateManyAndReturn, deleteMany, hasMany, belongsTo, hasOne,
       @VARCHAR, @TEXT, @NUMBER, @DOUBLE, @FLOAT, @UUID, @DATE, @TIMESTAMP, @JSON, @PrimaryKey, @AutoIncrement, @NotNull, @Unique


end  # module ORM

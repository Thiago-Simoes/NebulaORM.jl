using Dates

# Pre-defined SQL type constructors
 
function CHAR(size::Integer)::String
    return "CHAR($size)"
end

function VARCHAR(size)::String
    return "VARCHAR($(size))"
end

function TEXT()::String
    return "TEXT"
end

function INTEGER()::String
    return "INTEGER"
end

function DOUBLE()::String
    return "DOUBLE"
end

function FLOAT()::String
    return "FLOAT"
end

function DECIMAL(precision::Integer, scale::Integer)::String
    return "DECIMAL($precision,$scale)"
end

function BOOLEAN()::String
    return "BOOLEAN"
end

function TINYINT(size::Integer)::String
    return "TINYINT($size)"
end

function ENUM(values::Vector{<:AbstractString})::String
    let quoted = join(["'$(v)'" for v in values], ",")
        return "ENUM($quoted)"
    end
end

function SET(values::Vector{<:AbstractString})::String
    let quoted = join(["'$(v)'" for v in values], ",")
        return "SET($quoted)"
    end
end

function UUID()::String
    return "VARCHAR(36)"
end

function DATE()::String
    return "DATE"
end

function TIMESTAMP()::String
    return "TIMESTAMP"
end

function JSON()::String
    return "JSON"
end

# ---------------------------
# Base structs
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

Base.@kwdef mutable struct Index
    name::Union{Nothing,String} = nothing
    columns::Vector{String}
    unique::Bool = false
    lengths::Dict{String,Int} = Dict{String,Int}()
end



# ---------------------------
# Type functions
# ---------------------------
# ---------------------------
function mapSqlTypeToJulia(sqlType::String)
    s = uppercase(sqlType)
    if s == "INTEGER" || startswith(s, "INT")
        Int
    elseif s in ("FLOAT","DOUBLE") || startswith(s, "DOUBLE") || startswith(s, "FLOAT")
        Float64
    elseif startswith(s, "DECIMAL")
        Float64  # ou FixedPointNumbers/Decimal se quiser precisão
    elseif s == "TEXT" || startswith(s, "VARCHAR") || startswith(s, "CHAR") || startswith(s, "ENUM") || startswith(s, "SET")
        String
    elseif s == "TIMESTAMP"
        Dates.DateTime
    elseif s == "DATE"
        Dates.Date
    elseif s == "JSON"
        String  # futuro: JSON3.Object
    elseif s == "BOOLEAN" || startswith(s, "TINYINT(1)")
        Bool
    else
        Any
    end
end

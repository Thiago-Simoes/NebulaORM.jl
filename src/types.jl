using Dates

# Pre-defined SQL type constructors
 
function CHAR(size::Integer)::String
    return "CHAR($size)"
end

function VARCHAR(size)
    return "VARCHAR($(size))"
end

function TEXT()
    return :( "TEXT" )
end

function INTEGER()
    return :( "INTEGER" )
end

function DOUBLE()
    return :( "DOUBLE" )
end

function FLOAT()
    return :( "FLOAT" )
end

function DECIMAL(precision::Integer, scale::Integer)::String
    return "DECIMAL($precision,$scale)"
end

function BOOLEAN()
    return :( "BOOLEAN" )
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

function UUID()
    return :( "VARCHAR(36)" )
end

function DATE()
    return :( "DATE" )
end

function TIMESTAMP()
    return :( "TIMESTAMP" )
end

function JSON()
    return :( "JSON" )
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


# ---------------------------
# Type functions
# ---------------------------
# ---------------------------
function mapSqlTypeToJulia(sqlType::String)
    sqlType = uppercase(sqlType)
    if sqlType == "INTEGER"
        return Int
    elseif sqlType in ["FLOAT", "DOUBLE"]
        return Float64
    elseif sqlType == "TEXT"
        return String
    elseif sqlType == "TIMESTAMP"
        return Dates.DateTime
    elseif sqlType == "DATE"
        return Dates.Date
    elseif sqlType == "JSON"
        return String
    elseif sqlType == "UUID"
        return String
    else
        return Any
    end
end

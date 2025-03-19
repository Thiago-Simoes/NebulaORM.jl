
# Pre-defined SQL type constructors
# Are macros 
macro VARCHAR(size)
    return :( "VARCHAR($(size))" )
end

macro TEXT()
    return :( "TEXT" )
end

macro INTEGER()
    return :( "INTEGER" )
end

macro DOUBLE()
    return :( "DOUBLE" )
end

macro FLOAT()
    return :( "FLOAT" )
end

macro UUID()
    return :( "VARCHAR(36)" )
end

macro DATE()
    return :( "DATE" )
end

macro TIMESTAMP()
    return :( "TIMESTAMP" )
end

macro JSON()
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

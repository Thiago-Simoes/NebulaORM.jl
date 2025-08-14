# ---------------------------
# This file contains the macros for the keys in the database.
# ---------------------------
function PrimaryKey() 
    :( "PRIMARY KEY" )
end

function AutoIncrement()
    :( "AUTO_INCREMENT" )
end

function NotNull()
    :( "NOT NULL" )
end

const DF_DATE     = DateFormat("yyyy-mm-dd")
const DF_DATETIME = DateFormat("yyyy-mm-dd HH:MM:SS")

_as_string_literal(s::AbstractString) = "'" * replace(s, "'" => "''") * "'"

_strip_quotes(s::AbstractString) = begin
    raw = strip(s)
    if (startswith(raw, "'") && endswith(raw, "'")) ||
       (startswith(raw, "\"") && endswith(raw, "\""))
        return raw[2:end-1]
    end
    raw
end

function _match_default_func(raw::AbstractString)::Union{Nothing,String}
    m = match(r"^\s*CURRENT_TIMESTAMP\s*(\(\s*(\d*)\s*\))?\s*$"i, raw)
    if !isnothing(m)
        fsp = m.captures[2]
        return isnothing(fsp) || isempty(fsp) ? "DEFAULT CURRENT_TIMESTAMP()" :
                                               "DEFAULT CURRENT_TIMESTAMP($(strip(fsp)))"
    end
    if occursin(r"^\s*NOW\s*(\(\s*(\d*)\s*\))?\s*$"i, raw)
        return "DEFAULT CURRENT_TIMESTAMP()"
    end
    if occursin(r"^\s*CURRENT_DATE\s*(\(\s*\))?\s*$"i, raw)
        return "DEFAULT CURRENT_DATE"
    end
    if occursin(r"^\s*CURRENT_TIME\s*(\(\s*(\d*)\s*\))?\s*$"i, raw)
        return "DEFAULT CURRENT_TIME"
    end
    if occursin(r"^\s*LOCALTIME\s*(\(\s*(\d*)\s*\))?\s*$"i, raw)
        return "DEFAULT LOCALTIME"
    end
    if occursin(r"^\s*LOCALTIMESTAMP\s*(\(\s*(\d*)\s*\))?\s*$"i, raw)
        return "DEFAULT LOCALTIMESTAMP"
    end
    if occursin(r"^\s*UTC_TIMESTAMP\s*(\(\s*(\d*)\s*\))?\s*$"i, raw)
        return "DEFAULT UTC_TIMESTAMP"
    end
    nothing
end

function Default(defValue)
    s::Union{Nothing,String} = nothing
    if defValue isa AbstractVector{UInt8}
        s = String(copy(defValue))           
    elseif defValue isa AbstractString
        s = String(defValue)                 
    end


    if !isnothing(s)
        raw = _strip_quotes(s)

        if occursin(r"^\s*NULL\s*$"i, raw)
            return "DEFAULT NULL"
        end

        out = _match_default_func(raw)
        if !isnothing(out)
            return out
        end

        if occursin(r"^\s*[-+]?\d+(\.\d+)?\s*$", raw)
            return "DEFAULT $(strip(raw))"
        end

        return "DEFAULT " * _as_string_literal(raw)
    end

    if defValue isa Date
        return "DEFAULT " * _as_string_literal(Dates.format(defValue, DF_DATE))
    elseif defValue isa DateTime
        return "DEFAULT " * _as_string_literal(Dates.format(defValue, DF_DATETIME))
    elseif defValue isa Bool
        return defValue ? "DEFAULT TRUE" : "DEFAULT FALSE"
    elseif defValue === missing || defValue === nothing
        return "DEFAULT NULL"
    elseif defValue isa Real
        return "DEFAULT $(defValue)"
    else
        return "DEFAULT " * _as_string_literal(string(defValue))
    end
end


function Unique()
    :( "UNIQUE" )
end

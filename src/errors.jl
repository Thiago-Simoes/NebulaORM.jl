struct TableNotFoundError <: Exception
    table_name::String
end
Base.showerror(io::IO, e::TableNotFoundError) = print(io, "Table not found: ", e.table_name)

struct ModelNotRegisteredError <: Exception
    model_name::Symbol
end
Base.showerror(io::IO, e::ModelNotRegisteredError) = print(io, "Model not registered: ", e.model_name)

struct InvalidQueryError <: Exception
    details::String
end

Base.showerror(io::IO, e::InvalidQueryError) = print(io, "Invalid query: ", e.details)

struct InexistingRelationship <: Exception
    wanted::Symbol
    root::Symbol
end

function Base.showerror(io::IO, e::InexistingRelationship)
    print(io, "Inexisting relationship: '", String(e.wanted), "' not found in '", String(e.root), "'.")
end

struct RecordNotFoundError <: Exception
    model::Symbol
    details::String
end
Base.showerror(io::IO, e::RecordNotFoundError) = print(io, "Record not found for $(e.model): ", e.details)

struct RelationshipError <: Exception
    wanted::Symbol
    root::Symbol
end
Base.showerror(io::IO, e::RelationshipError) =
    print(io, "Relationship error: No relationship to '", String(e.wanted), "' from '", String(e.root), "'.")

struct OrderByError <: Exception
    details::String
end
Base.showerror(io::IO, e::OrderByError) = print(io, "orderBy error: ", e.details)

struct MissingPrimaryKeyError <: Exception
    model::Symbol
end
Base.showerror(io::IO, e::MissingPrimaryKeyError) = print(io, "Missing primary key on model ", e.model)

struct UnsupportedSQLTypeError <: Exception
    sql_type::String
end
Base.showerror(io::IO, e::UnsupportedSQLTypeError) = print(io, "Unsupported SQL type: ", e.sql_type)

struct UnsafeDeleteError <: Exception
    hint::String
end
Base.showerror(io::IO, e::UnsafeDeleteError) = print(io, "Unsafe delete: ", e.hint)

struct EmptyRecordsError <: Exception end
Base.showerror(io::IO, ::EmptyRecordsError) = print(io, "Batch insert requires at least one record")

struct DBExecutionError <: Exception
    sql::String
    params::Vector{Any}
    cause::Exception
end
Base.showerror(io::IO, e::DBExecutionError) = print(io, "DBExecutionError: ", sprint(showerror, e.cause), " | SQL=", e.sql, " | params=", e.params)


"""
  Retrieve list of all tables in current database.
"""
function getTables(conn::DBInterface.Connection)::Vector{String}
    sql = """
        SELECT TABLE_NAME AS table_name
        FROM information_schema.tables
        WHERE table_schema = ?
        ORDER BY TABLE_NAME
    """
    stmt = DBInterface.prepare(conn, sql)
    df = DataFrame(DBInterface.execute(stmt, [ENV["DB_NAME"]]))
    return collect(df.table_name)
end


"""
  Retrieve FK dependencies for ALL tables as a Dict:
  deps[t] = Set of tables that `t` depends on (i.e., `t` has FK to those tables).
  Self-FKs are ignored for sorting (não bloqueiam a ordem).
"""
function getAllDependencies(conn::DBInterface.Connection, tables::Vector{String})::Dict{String, Set{String}}
    sql = """
        SELECT table_name, referenced_table_name
        FROM information_schema.key_column_usage
        WHERE table_schema = ?
          AND referenced_table_name IS NOT NULL
    """
    stmt = DBInterface.prepare(conn, sql)
    df = DataFrame(DBInterface.execute(stmt, [ENV["DB_NAME"]]))
    DBInterface.close!(stmt)

    deps = Dict{String, Set{String}}(t => Set{String}() for t in tables)
    for r in eachrow(df)
        t  = String(r.TABLE_NAME)
        rt = String(r.REFERENCED_TABLE_NAME)
        if haskey(deps, t) && haskey(deps, rt) && t != rt
            push!(deps[t], rt)
        end
    end
    return deps
end


"""
  Topologically sort tables so that referenced tables come first.
  If cycle exists, preserva determinismo e dá warn, jogando o resto no final (ordem alfabética).
"""
function topoSortTables(conn::DBInterface.Connection, tables::Vector{String})::Vector{String}
    deps = getAllDependencies(conn, tables)                 # t -> {rt1, rt2, ...} (t depende de rt*)
    # indegree conta quantos dependem DELE? Não: contamos quantas dependências CADA t tem.
    indeg = Dict(t => length(deps[t]) for t in tables)

    # build reverse adjacency: rev[rt] = {t1, t2, ...} (quem depende de rt)
    rev = Dict{String, Set{String}}(t => Set{String}() for t in tables)
    for (t, s) in deps
        for rt in s
            push!(rev[rt], t)
        end
    end

    # fila inicial: quem não depende de ninguém (indegree 0)
    q = sort([t for (t, d) in indeg if d == 0])  # determinístico
    out = String[]

    while !isempty(q)
        # pop o primeiro em ordem alfabética
        t = popfirst!(q)
        push!(out, t)
        # reduzir indegree de quem depende de t
        for nxt in sort(collect(rev[t]))  # mantém determinismo
            indeg[nxt] -= 1
            if indeg[nxt] == 0
                # insere mantendo ordenação
                insert_at = searchsortedfirst(q, nxt)
                insert!(q, insert_at, nxt)
            end
        end
    end

    if length(out) != length(tables)
        # Existe ciclo (ex: tabelas mutuamente dependentes). Resolve jogando o resto no fim.
        rem = setdiff(tables, out) |> sort
        @warn "Ciclo de dependência detectado entre tabelas: $(join(rem, ",")). Ordenando ciclicas no final."
        append!(out, rem)
    end

    return out
end


"""
  Retrieve column metadata for given table.
  Returns a DataFrame with: column_name, data_type, character_maximum_length,
  is_nullable, column_key, extra, column_default.
"""
function getColumns(conn::DBInterface.Connection, table::String)::DataFrame
    sql = """
        SELECT *
        FROM information_schema.columns
        WHERE table_schema = ? AND table_name = ?
        ORDER BY ordinal_position
    """
    stmt = DBInterface.prepare(conn, sql)
    df = DataFrame(DBInterface.execute(stmt, [ENV["DB_NAME"], table]))
    DBInterface.close!(stmt)
    return df
end

"""
  Map SQL column metadata row to `columnsDef` tuple.
"""
function mapColumnDef(row)::Tuple{String,String,Vector{Any}}
    sql_type = uppercase(row.DATA_TYPE |> String)
    julia_sql = if sql_type == "VARCHAR"
        string(VARCHAR(row.CHARACTER_MAXIMUM_LENGTH))
    elseif sql_type == "TEXT"
        "TEXT()"
    elseif sql_type in ("INT","INTEGER","BIGINT")
        "INTEGER()"
    elseif sql_type == "DOUBLE"
        "DOUBLE()"
    elseif sql_type == "FLOAT"
        "FLOAT()"
    elseif sql_type == "DECIMAL"
        string(DECIMAL(Int(row.NUMERIC_PRECISION), Int(row.NUMERIC_SCALE)))
    elseif sql_type == "DATE"
        "DATE()"
    elseif sql_type == "TIMESTAMP"
        "TIMESTAMP()"
    elseif sql_type == "JSON"
        "JSON()"
    else
        throw(UnsupportedSQLTypeError(sql_type))
    end
    cons = String[]
    push!(cons, row.IS_NULLABLE == "NO" ? string(NotNull()) : nothing)
    if row.COLUMN_KEY == "PRI"
        push!(cons, string(PrimaryKey()))
        row.EXTRA == "auto_increment" && push!(cons, string(AutoIncrement()))
    elseif row.COLUMN_KEY == "UNI"
        push!(cons, string(Unique()))
    end
    if !ismissing(row.COLUMN_DEFAULT) && !isempty(row.COLUMN_DEFAULT) # Preserves default values for other types and functions
        push!(cons, string(Default(row.COLUMN_DEFAULT)))
    end
    cons = filter(!isnothing, cons)
    return (row.COLUMN_NAME, julia_sql, cons)
end

"""
  Retrieve foreign-key relationships for table.
  Returns Vector of (field::Symbol, target::Symbol, target_field::String, :belongsTo)
"""
function getRelationships(conn::DBInterface.Connection, table::String)
    sql = """
        SELECT column_name, referenced_table_name, referenced_column_name
        FROM information_schema.key_column_usage
        WHERE table_schema = ?
          AND table_name = ?
          AND referenced_table_name IS NOT NULL
    """
    stmt = DBInterface.prepare(conn, sql)
    rows = DataFrame(DBInterface.execute(stmt, [ENV["DB_NAME"], table]))
    DBInterface.close!(stmt)
    return [(Symbol(r.COLUMN_NAME), Symbol(r.REFERENCED_TABLE_NAME), r.REFERENCED_COLUMN_NAME, :belongsTo) for r in eachrow(rows)]
end

"""
  Retrieve unique index definitions for table.
  Returns Vector of Vector{String} (columns per index).
"""
function getIndexes(conn::DBInterface.Connection, table::String)
    sql = """
        SELECT INDEX_NAME, COLUMN_NAME
        FROM information_schema.statistics
        WHERE table_schema = ?
          AND table_name = ?
          AND NON_UNIQUE = 1
        ORDER BY index_name, seq_in_index
    """
    stmt = DBInterface.prepare(conn, sql)
    df = DataFrame(DBInterface.execute(stmt, [ENV["DB_NAME"], table]))
    DBInterface.close!(stmt)
    filter!(r -> r.INDEX_NAME != "PRIMARY", df)  # remove primary key index

    by_idx = groupby(df, :INDEX_NAME)
    return [collect(g.COLUMN_NAME) for g in by_idx]
end

"""
  Generate `Model` code for all tables in the database.
  Returns a string containing Julia code.
"""
function generateModels()::String
    conn = dbConnection()
    raw_tables = getTables(conn)
    tables = topoSortTables(conn, raw_tables)

    buf = IOBuffer()
    println(buf, "using OrionORM")

    for tbl in tables
        println(buf, "\n# Table: $tbl")
        try
            cols_defs = [mapColumnDef(r) for r in eachrow(getColumns(conn, tbl))]
            rels      = getRelationships(conn, tbl)
            idxs      = getIndexes(conn, tbl)

            println(buf, "Model(:$tbl, [")
            for (name, sqlty, cons) in cols_defs
                println(buf, "  (\"$name\", $sqlty, $(cons)),")
            end
            
            if isempty(idxs)
                println(buf, "], $(rels))")
            else
                println(buf, "], $(rels), $((idxs)))")
            end
        catch err
            @warn "Skipping table $tbl due to generation error: $err"
        end
    end

    return String(take!(buf))
end
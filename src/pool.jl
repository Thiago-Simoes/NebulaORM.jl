module Pool

using DBInterface
using MySQL
using DotEnv

# Lê POOL_SIZE do ENV ou usa 5 se não definido
const POOL_SIZE = get(ENV, "POOL_SIZE", "5") |> x -> parse(Int, x)
const connection_pool = Channel{MySQL.Connection}(POOL_SIZE)

# Cria uma nova conexão
function create_connection()
    dbHost     = ENV["DB_HOST"]
    dbUser     = ENV["DB_USER"]
    dbPassword = ENV["DB_PASSWORD"]
    dbName     = ENV["DB_NAME"]
    dbPort     = parse(Int, string(ENV["DB_PORT"]))
    return DBInterface.connect(MySQL.Connection, dbHost, dbUser, dbPassword, db=dbName, port=dbPort, reconnect=true)
end

function init_pool()
    # Limpa conexões existentes, se houver
    while isready(connection_pool)
        take!(connection_pool)
    end
    # DotEnv.load!()  # se necessário
    for _ in 1:POOL_SIZE
        conn = create_connection()
        put!(connection_pool, conn)
    end
end

# Verifica se a conexão está ativa; se não, cria nova.
function validate_connection(conn)
    try
        DBInterface.execute(conn, "SELECT 1")
        return conn
    catch
        return create_connection()
    end
end

function getConnection()
    local conn = take!(connection_pool)

    # Verifica se conexões disponíveis estão abaixo da metade do pool
    if connection_pool.n_avail_items < ceil(Int, POOL_SIZE / 2)
        @async begin
            while length(connection_pool) < POOL_SIZE
                new_conn = create_connection()
                put!(connection_pool, new_conn)
            end
        end
    end
    return conn
end

function releaseConnection(conn)
    put!(connection_pool, conn)
end

export init_pool, getConnection, releaseConnection, connection_pool

end # module Pool

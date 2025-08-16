module Pool

using DBInterface
using MySQL
using DotEnv
using Dates

const connectionPool = Channel{Tuple{MySQL.Connection, DateTime}}(Inf)
const poolSize = Ref(5)
const poolInitialized = Ref(false)
const poolLock = ReentrantLock()
const watchdogInterval = Ref{Float64}(3600.0)

const maxRetries = 3
const initialBackoff = 0.5

function __init__()
    DotEnv.load!()
    watchdogInterval[] = parse(Float64, get(ENV, "POOL_RECYCLE_TIMEOUT", "3600"))
end

function createConnection()
    retries = 0
    while retries < maxRetries
        try
            dbHost = ENV["DB_HOST"]
            dbUser = ENV["DB_USER"]
            dbPassword = ENV["DB_PASSWORD"]
            dbName = ENV["DB_NAME"]
            dbPort = parse(Int, ENV["DB_PORT"])
            return DBInterface.connect(
                MySQL.Connection,
                dbHost,
                dbUser,
                dbPassword,
                db=dbName,
                port=dbPort,
                reconnect=true
            )
        catch e
            retries += 1
            if retries < maxRetries
                backoffTime = initialBackoff * (2^(retries - 1))
                sleep(backoffTime)
            else
                rethrow(e)
            end
        end
    end
end

function replenishPool()
    if !trylock(poolLock)
        return
    end
    try
        while (connectionPool.n_avail_items) < poolSize[]
            put!(connectionPool, (createConnection(), now()))
        end
    finally
        unlock(poolLock)
    end
end

function initPool(size::Int=5)
    lock(poolLock) do
        if poolInitialized[]
            return
        end
        poolSize[] = size
        for _ in 1:poolSize[]
            conn = createConnection()
            put!(connectionPool, (conn, now()))
        end
        poolInitialized[] = true
    end
    @async watchdog()
end

function watchdog()
    Timer(0.0, interval=watchdogInterval[]) do timer
        lock(poolLock) do
            connsToRecycle = Tuple{MySQL.Connection, DateTime}[]
            for _ in 1:(connectionPool.n_avail_items)
                conn, creationTime = take!(connectionPool)
                if now() - creationTime > Second(watchdogInterval[])
                    try
                        DBInterface.close(conn)
                    catch e
                        @warn "Failed to close recycled connection" exception=(e,)
                    end
                else
                    push!(connsToRecycle, (conn, creationTime))
                end
            end
            for connTuple in connsToRecycle
                put!(connectionPool, connTuple)
            end
        end
        replenishPool()
    end
end

function getConnection()
    conn, _ = take!(connectionPool)
    return conn
end

function releaseConnection(conn::MySQL.Connection)
    put!(connectionPool, (conn, now()))
    @async replenishPool()
end

export initPool, getConnection, releaseConnection

end
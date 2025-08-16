using DotEnv
using MySQL
using DBInterface
using .Pool

# ---------------------------
# Connection to the database
# ---------------------------
__POOL_INITIALIZED__ = false

function dbConnection()
    if !__POOL_INITIALIZED__
        Pool.initPool()
        global __POOL_INITIALIZED__ = true
    end
    
    return Pool.getConnection()
end

function releaseConnection(conn)
    Pool.releaseConnection(conn)
end
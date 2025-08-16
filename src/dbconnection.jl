using DotEnv
using MySQL
using DBInterface
using .Pool

# ---------------------------
# Connection to the database
# ---------------------------
function dbConnection()
    if isempty(Pool.connection_pool)
        Pool.init_pool()
    end

    return Pool.getConnection()
end

function releaseConnection(conn)
    Pool.releaseConnection(conn)
end
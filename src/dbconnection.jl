using DotEnv
using MySQL
using DBInterface
using .Pool

# ---------------------------
# Connection to the database
# ---------------------------
function dbConnection()
    return Pool.getConnection()
end

function releaseConnection(conn)
    Pool.releaseConnection(conn)
end
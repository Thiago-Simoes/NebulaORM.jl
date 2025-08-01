function getLastInsertId()
    conn = dbConnection()
    result = DBInterface.execute(conn, "SELECT LAST_INSERT_ID() as id") |> DataFrame
    row = first(result)
    releaseConnection(conn)
    return row.id |> Int
end


function serialize(instance)
    local d = Dict{String,Any}()
    for field in fieldnames(typeof(instance))
        d[string(field)] = getfield(instance, field)
    end
    return d
end


function generateUuid()
    return string(uuid4())
end

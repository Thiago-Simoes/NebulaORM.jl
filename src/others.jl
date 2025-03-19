function getLastInsertId(conn)
    result = DBInterface.execute(conn, "SELECT LAST_INSERT_ID() as id")
    row = first(result) |> DataFrame
    return row[1, :id]
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

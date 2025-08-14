# ---------------------------
# Relationship Helper Functions
# ---------------------------

function hasMany(parentInstance, relationName)
    parentType = typeof(parentInstance)
    relationships = getRelationships(parentType)
    for rel in relationships
        if rel.field == relationName && rel.type == :hasMany
            pkCol = getPrimaryKeyColumn(parentType)
            if pkCol === nothing
                throw(MissingPrimaryKeyError(nameof(parentType)))
            end
            parentValue = getfield(parentInstance, Symbol(pkCol.name))
            return findMany(resolveModel(rel.targetModel); query=Dict("where" => Dict(rel.targetField => parentValue)))
        end
    end
    throw(InexistingRelationship(relationName, nameof(parentType)))
end

function hasMany(parentInstance, relatedModel::DataType, foreignKey::String)
    local parentType = typeof(parentInstance)
    local pkCol = getPrimaryKeyColumn(parentType)
    if pkCol === nothing
        throw(MissingPrimaryKeyError(nameof(parentType)))
    end
    local parentValue = getfield(parentInstance, Symbol(pkCol.name))
    return findMany(relatedModel; query=Dict("where" => Dict(foreignKey => parentValue)))
end

function belongsTo(childInstance, relationName)
    childType = typeof(childInstance)
    relationships = getRelationships(childType)
    for rel in relationships
        if rel.field == relationName && rel.type == :belongsTo
            childFKValue = getfield(childInstance, Symbol(rel.field))
            return findFirst(resolveModel(rel.targetModel); query=Dict("where" => Dict(rel.targetField => childFKValue)))
        end
    end
    throw(InexistingRelationship(relationName, nameof(childType)))
end

# Overload para belongsTo com 3 parâmetros
function belongsTo(childInstance, relatedModel::DataType, foreignKey::String)
    local childValue = getfield(childInstance, Symbol(foreignKey))
    local pk = getPrimaryKeyColumn(relatedModel)
    if pk === nothing
        error("No primary key defined for model $(relatedModel)")
    end
    return findFirst(relatedModel; query=Dict("where" => Dict(pk.name => childValue)))
end

# Versão registrada para hasOne
function hasOne(parentInstance, relationName)
    parentType = typeof(parentInstance)
    relationships = getRelationships(parentType)
    for rel in relationships
        if rel.field == relationName && rel.type == :hasOne
            pkCol = getPrimaryKeyColumn(parentType)
            if pkCol === nothing
                error("No primary key defined for model $(parentType)")
            end
            local parentValue = getfield(parentInstance, Symbol(pkCol.name))
            return findFirst(resolveModel(rel.targetModel); query=Dict("where" => Dict(rel.targetField => parentValue)))
        end
    end
    error("No hasOne relationship found with name $relationName for model $(parentType)")
end

# Overload para hasOne com 3 parâmetros
function hasOne(parentInstance, relatedModel::DataType, foreignKey::String)
    local parentType = typeof(parentInstance)
    local pkCol = getPrimaryKeyColumn(parentType)
    if pkCol === nothing
        error("No primary key defined for model $(parentType)")
    end
    local parentValue = getfield(parentInstance, Symbol(pkCol.name))
    return findFirst(relatedModel; query=Dict("where" => Dict(foreignKey => parentValue)))
end
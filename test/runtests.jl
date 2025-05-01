# Implementa os testes unitários para o módulo `ORM.jl` e suas dependências.
import Pkg
Pkg.activate("..")
# ... incluir outros arquivos de teste conforme necessário ...

using Test
using NebulaORM

# Setup: Obter conexão e dropar as tabelas de teste, se existirem
conn = dbConnection()
dropTable!(conn, "User")
dropTable!(conn, "Post")

# Define um modelo de teste com chave primária "id"
@Model User (
    ("id", @INTEGER, [@PrimaryKey(), @AutoIncrement()]),
    ("name", @TEXT, [@NotNull()]),
    ("email", @TEXT, [@Unique(), @NotNull()])
) [
    ("posts", Post, "authorId", :hasMany)
]

@Model Post (
    ("id", @INTEGER, [@PrimaryKey(), @AutoIncrement()]),
    ("title", @TEXT, [@NotNull()]),
    ("authorId", @INTEGER, [@NotNull()])
) [
    ("authorId", User, "id", :belongsTo)
]

@testset "NebulaORM Basic CRUD Tests" begin
    # ------------------------------
    # Teste: Criar um registro
    # ------------------------------
    userData = Dict("name" => "Thiago", "email" => "thiago@example.com", "cpf" => "00000000000")
    user = create(User, userData)
    @test user.name == "Thiago"
    @test user.email == "thiago@example.com"
    @test hasproperty(user, :id)  # A chave primária deve estar definida

    # ------------------------------
    # Teste: Buscar registro com filtro (usando query dict)
    # ------------------------------
    foundUser = findFirst(User; query=Dict("where" => Dict("name" => "Thiago")))
    @test foundUser !== nothing
    @test foundUser.id == user.id

    # ------------------------------
    # Teste: Atualizar registro usando função update com query dict
    # ------------------------------
    updatedUser = update(User, Dict("where" => Dict("id" => user.id)), Dict("name" => "Thiago Updated"))
    @test updatedUser.name == "Thiago Updated"

    # ------------------------------
    # Teste: Upsert - atualizar se existir, criar se não existir
    # ------------------------------
    upsertUser = upsert(User, "email", "thiago@example.com",
                        Dict("name" => "Thiago Upserted", "email" => "thiago@example.com"))
    @test upsertUser.name == "Thiago Upserted"

    # ------------------------------
    # Teste: Atualizar registro via método de instância
    # ------------------------------
    foundUser.name = "Thiago Instance"
    updatedInstance = update(foundUser)
    @test updatedInstance.name == "Thiago Instance"

    # ------------------------------
    # Teste: Deletar registro via método de instância
    # ------------------------------
    deleteResult = delete(foundUser)
    @test deleteResult === true

    # ------------------------------
    # Teste: Criar múltiplos registros
    # ------------------------------
    records = [
        Dict("name" => "Bob", "email" => "bob@example.com", "cpf" => "11111111111"),
        Dict("name" => "Carol", "email" => "carol@example.com", "cpf" => "22222222222")
    ]
    createdRecords = createMany(User, records)
    @test length(createdRecords) == 2

    # ------------------------------
    # Teste: Buscar vários registros (query dict vazio)
    # ------------------------------
    manyUsers = findMany(User)
    @test length(manyUsers) ≥ 2

    # ------------------------------
    # Teste: Atualizar vários registros usando query dict
    # ------------------------------
    uMany = updateMany(User, Dict("where" => Dict("name" => "Bob")), Dict("name" => "Bob Updated"))
    for u in uMany
        @test u.name == "Bob Updated"
    end

    # ------------------------------
    # Teste: Atualizar vários registros e retornar os registros atualizados
    # ------------------------------
    updatedManyAndReturn = updateManyAndReturn(User, Dict("where" => Dict("name" => "Carol")), Dict("name" => "Carol Updated"))
    for u in updatedManyAndReturn
        @test u.name == "Carol Updated"
    end

    # ------------------------------
    # Teste: Criar registro relacionado (Post)
    # ------------------------------
    userData = Dict("name" => "Thiago", "email" => "thiago@example.com", "cpf" => "00000000000")
    user = create(User, userData)
    postData = Dict("title" => "My First Post", "authorId" => user.id)
    post = create(Post, postData)
    @test post.title == "My First Post"
    @test post.authorId == user.id

    # ------------------------------
    # Teste: Buscar registros relacionados
    # ------------------------------
    @test hasMany(user, Post, "authorId")[1].title == "My First Post"

    # ------------------------------
    # Teste: Deletar vários registros usando query dict
    # ------------------------------
    deleteManyResult = deleteMany(User, Dict("where" => "1=1"))
    @test deleteManyResult === true
end

@testset "NebulaORM Relationships Tests" begin
    userData = Dict("name" => "Thiago", "email" => "thiago@example.com", "cpf" => "00000000000")
    user = create(User, userData)

    foundUser = findFirst(User; query=Dict("where" => Dict("name" => "Thiago")))

    postData = Dict("title" => "My First Post", "authorId" => user.id)
    post = create(Post, postData)

    userWithPosts = findFirst(User; query=Dict("where" => Dict("name" => "Thiago"), "include" => [Post]))
    @test length(userWithPosts["Post"]) == 1
    @test typeof(userWithPosts["Post"][1]) <: Post
    @test userWithPosts["Post"][1].title == "My First Post"
    @test userWithPosts["Post"][1].authorId == user.id

end

@testset "NebulaORM Pagination Tests" begin
    # Cria registros para paginação
    # Limpa registros anteriores (se necessário)
    deleteMany(User, Dict("where" => "1=1"))
    
    # Cria uma lista de 5 usuários com nomes numerados
    usersData = [ Dict("name" => "User $(i)", "email" => "user$(i)@example.com", "cpf" => string(1000 + i)) for i in 1:5 ]
    createdUsers = createMany(User, usersData)
    @test length(createdUsers) == 5

    # Teste: Recupera 2 usuários por vez, começando do primeiro
    page1 = findMany(User; query=Dict("limit" => 2, "offset" => 0, "orderBy" => "id"))
    @test length(page1) == 2
    @test page1[1].name == "User 1"
    @test page1[2].name == "User 2"

    # Teste: Recupera os próximos 2 usuários a partir do terceiro
    page2 = findMany(User; query=Dict("limit" => 2, "offset" => 2, "orderBy" => "id"))
    @test length(page2) == 2
    @test page2[1].name == "User 3"
    @test page2[2].name == "User 4"

    # Teste: Recupera os registros restantes
    page3 = findMany(User; query=Dict("limit" => 2, "offset" => 4, "orderBy" => "id"))
    @test length(page3) == 1
    @test page3[1].name == "User 5"
end

# Cleanup: Opcionalmente dropar as tabelas de teste
# dropTable!(conn, "User")
# dropTable!(conn, "Post")

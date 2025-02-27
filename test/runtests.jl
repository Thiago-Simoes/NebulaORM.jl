# Implementa os testes unitários para o módulo `ORM.jl' e suas dependências.
import Pkg
Pkg.activate("..")
# ... include other test files as needed ...

using Test
using ORM

# Setup: Obter conexão e dropar a tabela de teste se existir
conn = dbConnection()
dropTable!(conn, "User")
dropTable!(conn, "Post")

# Define um modelo de teste com chave primária "user_id"
@Model User (
    ("id", "INTEGER", [@PrimaryKey(), @AutoIncrement()]),
    ("name", "TEXT", [@NotNull()]),
    ("email", "TEXT", [@Unique(), @NotNull()])
) [
    ("posts", Post, "authorId", :hasMany)
]

@Model Post (
    ("id", "INTEGER", [@PrimaryKey(), @AutoIncrement()]),
    ("title", "TEXT", [@NotNull()]),
    ("authorId", "INTEGER", [@NotNull()])
) [
    ("author", User, "authorId", :belongsTo)
]

@testset "SimpleORM Basic CRUD Tests" begin
    # ------------------------------
    # Teste: Criar um registro
    # ------------------------------
    userData = Dict("name" => "Thiago", "email" => "thiago@example.com", "cpf" => "00000000000")
    user = create(User, userData)
    @test user.name == "Thiago"
    @test user.email == "thiago@example.com"
    @test hasproperty(user, :id)  # Deve ter a chave primária definida

    # ------------------------------
    # Teste: Buscar registro com filtro
    # ------------------------------
    foundUser = findFirst(User; filter="name = 'Thiago'")
    @test foundUser !== nothing
    @test foundUser.id == user.id

    # ------------------------------
    # Teste: Atualizar registro usando função por tipo
    # ------------------------------
    updatedUser = update(User, "id = $(user.id)", Dict("name" => "Thiago Updated"))
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
    # Teste: Buscar vários registros
    # ------------------------------
    manyUsers = findMany(User)
    @test length(manyUsers) ≥ 2

    # ------------------------------
    # Teste: Atualizar vários registros
    # ------------------------------
    updatedMany = updateMany(User, "name LIKE 'Bob%'", Dict("name" => "Bob Updated"))
    for u in updatedMany
        @test u.name == "Bob Updated"
    end

    # ------------------------------
    # Teste: Filtragem usando keyword arguments
    # ------------------------------
    _ = createMany(User, [
        Dict("name" => "Dan", "email" => "dan@example.com", "cpf" => "33333333333"),
        Dict("name" => "Eve", "email" => "eve@example.com", "cpf" => "44444444444")
    ])
    filteredUsers = filter(User; name="Dan")
    @test length(filteredUsers) == 1
    @test filteredUsers[1].name == "Dan"

    # ------------------------------
    # Teste: Buscar registros relacionados
    # ------------------------------
    postData = Dict("title" => "My First Post", "authorId" => user.id)
    post = create(Post, postData)
    @test post.title == "My First Post"
    @test post.authorId == user.id

    @test hasMany(user, Post, "authorId")[1].title == "My First Post"
    @test belongsTo(post, User, "authorId").name == "Thiago"

    # ------------------------------
    # Teste: Deletar vários registros
    # ------------------------------
    deleteManyResult = deleteMany(User, "1=1")
    @test deleteManyResult === true
end

# Cleanup: Dropar a tabela de teste
# dropTable!(conn, "User")
# dropTable!(conn, "Post")

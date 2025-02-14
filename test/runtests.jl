# Implementa os testes unitários para o módulo `ORM.jl' e suas dependências.
import Pkg
Pkg.activate("..")
# ... include other test files as needed ...

using Test
using ORM

# Setup: Obter conexão e dropar a tabela de teste se existir
conn = dbConnection()
dropTable!(conn, "TestUser")

# Define um modelo de teste com chave primária "user_id"
@Model User (
    ("id", "INTEGER", [@PrimaryKey(), @AutoIncrement()]),
    ("name", "TEXT", [@NotNull()]),
    ("email", "TEXT", [@Unique(), @NotNull()]),
    ("cpf", "VARCHAR(11)", [@Unique(), @NotNull()]),
    ("age", "INTEGER", [])
)

@testset "SimpleORM Basic CRUD Tests" begin
    # ------------------------------
    # Teste: Criar um registro
    # ------------------------------
    userData = Dict("name" => "Thiago", "email" => "thiago@example.com", "cpf" => "00000000000")
    user = create(User, userData)
    @test user.name == "Alice"
    @test user.email == "alice@example.com"
    @test hasproperty(user, :user_id)  # Deve ter a chave primária definida

    # ------------------------------
    # Teste: Buscar registro com filtro
    # ------------------------------
    foundUser = findFirst(TestUser; filter="name = 'Alice'")
    @test foundUser !== nothing
    @test foundUser.user_id == user.user_id

    # ------------------------------
    # Teste: Atualizar registro usando função por tipo
    # ------------------------------
    updatedUser = update(TestUser, "user_id = $(user.user_id)", Dict("name" => "Alice Updated"))
    @test updatedUser.name == "Alice Updated"

    # ------------------------------
    # Teste: Upsert - atualizar se existir, criar se não existir
    # ------------------------------
    upsertUser = upsert(TestUser, "email", "alice@example.com",
                        Dict("name" => "Alice Upserted", "email" => "alice@example.com"))
    @test upsertUser.name == "Alice Upserted"

    # ------------------------------
    # Teste: Atualizar registro via método de instância
    # ------------------------------
    foundUser.name = "Alice Instance"
    updatedInstance = update(foundUser)
    @test updatedInstance.name == "Alice Instance"

    # ------------------------------
    # Teste: Deletar registro via método de instância
    # ------------------------------
    deleteResult = delete(foundUser)
    @test deleteResult === true

    # ------------------------------
    # Teste: Criar múltiplos registros
    # ------------------------------
    records = [
        Dict("name" => "Bob", "email" => "bob@example.com"),
        Dict("name" => "Carol", "email" => "carol@example.com")
    ]
    createdRecords = createMany(TestUser, records)
    @test length(createdRecords) == 2

    # ------------------------------
    # Teste: Buscar vários registros
    # ------------------------------
    manyUsers = findMany(TestUser)
    @test length(manyUsers) ≥ 2

    # ------------------------------
    # Teste: Atualizar vários registros
    # ------------------------------
    updatedMany = updateMany(TestUser, "name LIKE 'Bob%'", Dict("name" => "Bob Updated"))
    for u in updatedMany
        @test u.name == "Bob Updated"
    end

    # ------------------------------
    # Teste: Filtragem usando keyword arguments
    # ------------------------------
    _ = createMany(TestUser, [
        Dict("name" => "Dan", "email" => "dan@example.com"),
        Dict("name" => "Eve", "email" => "eve@example.com")
    ])
    filteredUsers = filter(TestUser; name="Dan")
    @test length(filteredUsers) == 1
    @test filteredUsers[1].name == "Dan"

    # ------------------------------
    # Teste: Deletar vários registros
    # ------------------------------
    deleteManyResult = deleteMany(TestUser, "1=1")
    @test deleteManyResult === true
end

# Cleanup: Dropar a tabela de teste
dropTable!(conn, "TestUser")

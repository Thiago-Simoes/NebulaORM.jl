import Pkg
Pkg.activate("..")

using Test
using Dates

using BenchmarkTools
using Random

using DotEnv

DotEnv.load!() 

using OrionORM
using DBInterface

conn = dbConnection()
dropTable!(conn, "User")
dropTable!(conn, "Post")
releaseConnection(conn)

Model(
    :User,
    [
        ("id", INTEGER(), [PrimaryKey(), AutoIncrement()]),
        ("name", VARCHAR(50), [NotNull()]),
        ("email", TEXT(), [Unique(), NotNull()])
    ]
)

Model(
    :Post,
    [
        ("id", INTEGER(), [PrimaryKey(), AutoIncrement()]),
        ("title", TEXT(), [NotNull()]),
        ("authorId", INTEGER(), [NotNull()]),
        ("createdAt", TIMESTAMP(), [NotNull(), Default("CURRENT_TIMESTAMP()")])
    ],
    [
        ("authorId", User, "id", :belongsTo)
    ]
)


@testset verbose = true "OrionORM" begin
    @testset "OrionORM Basic CRUD Tests" begin
        userData = Dict("name" => "Thiago", "email" => "thiago@example.com", "cpf" => "00000000000")
        user = create(User, userData)
        @test user.name == "Thiago"
        @test user.email == "thiago@example.com"
        @test hasproperty(user, :id) 

        foundUser = findFirst(User; query=Dict("where" => Dict("name" => "Thiago")))
        @test foundUser !== nothing
        @test foundUser.id == user.id

        updatedUser = update(User, Dict("where" => Dict("id" => user.id)), Dict("name" => "Thiago Updated"))
        @test updatedUser.name == "Thiago Updated"

        upsertUser = upsert(User, "email", "thiago@example.com",
                            Dict("name" => "Thiago Upserted", "email" => "thiago@example.com"))
        @test upsertUser.name == "Thiago Upserted"

        foundUser.name = "Thiago Instance"
        updatedInstance = update(foundUser)
        @test updatedInstance.name == "Thiago Instance"

        deleteResult = delete(foundUser)
        @test deleteResult === true

        records = [
            Dict("name" => "Bob", "email" => "bob@example.com", "cpf" => "11111111111"),
            Dict("name" => "Carol", "email" => "carol@example.com", "cpf" => "22222222222")
        ]
        createdRecords = createMany(User, records)
        @test createdRecords == true

        manyUsers = findMany(User)
        @test length(manyUsers) ≥ 2

        uMany = updateMany(User, Dict("where" => Dict("name" => "Bob")), Dict("name" => "Bob Updated"))
        
        for u in uMany
            @test u.name == "Bob Updated"
        end

        userData = Dict("name" => "Thiago", "email" => "thiago@example.com", "cpf" => "00000000000")
        user = create(User, userData)
        postData = Dict("title" => "My First Post", "authorId" => user.id)
        post = create(Post, postData)
        @test post.title == "My First Post"
        @test post.authorId == user.id

        @test hasMany(user, Post, "authorId")[1].title == "My First Post"

        @test_throws ErrorException deleteMany(User, Dict("where" => Dict()))
        deleteManyResult = deleteMany(User, Dict("where" => Dict()), forceDelete=true)
        @test deleteManyResult === true
    end

    @testset "OrionORM Relationships Tests" begin
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

    @testset "OrionORM Pagination Tests" begin
        deleteMany(User, Dict("where" => Dict()), forceDelete=true)

        usersData = [ Dict("name" => "User $(i)", "email" => "user$(i)@example.com", "cpf" => string(1000 + i)) for i in 1:5 ]
        createdUsers = createMany(User, usersData)
        @test createdUsers == true
        @test length(findMany(User)) == 5  

        page1 = findMany(User; query=Dict("limit" => 2, "offset" => 0, "orderBy" => "id"))
        @test length(page1) == 2
        @test page1[1].name == "User 1"
        @test page1[2].name == "User 2"

        page2 = findMany(User; query=Dict("limit" => 2, "offset" => 2, "orderBy" => "id"))
        @test length(page2) == 2
        @test page2[1].name == "User 3"
        @test page2[2].name == "User 4"

        page3 = findMany(User; query=Dict("limit" => 2, "offset" => 4, "orderBy" => "id"))
        @test length(page3) == 1
        @test page3[1].name == "User 5"
    end

    @testset "OrionORM Bulk Operations & Benchmarks" begin
        deleteMany(User, Dict("where" => Dict()), forceDelete=true)
    
        N = 100
        user_payloads = [Dict("name" => "BenchUser$(i)",
                              "email" => "bench$(i)@example.com") for i in 1:N]
    
        t_insert = @elapsed for payload in user_payloads
            create(User, payload)
        end
        @info "100 inserts sequenciais em $(t_insert) segundos"
    
        @test length(findMany(User)) == N
    
        t_select = @elapsed for _ in 1:N
            idx = rand(1:N)
            findFirst(User; query=Dict("where" => Dict("email" => "bench$(idx)@example.com")))
        end
        @info "100 selects sequenciais em $(t_select) segundos"
    
        sample = findFirst(User; query=Dict("where" => Dict("email" => "bench1@example.com")))
        @test sample !== nothing && sample.email == "bench1@example.com"
    end

    @testset "OrionORM Error handling" begin
        @test_throws ErrorException update(User, Dict(), Dict("name"=>"x"))
        @test_throws ErrorException delete(User, Dict())
    end
    
    @testset "OrionORM QueryBuilder operators" begin
        deleteMany(User, Dict("where"=>Dict()), forceDelete=true)
        create(User, Dict("name"=>"apple","email"=>"apple@e.com"))
        create(User, Dict("name"=>"banana","email"=>"banana@e.com"))
        create(User, Dict("name"=>"apricot","email"=>"apricot@e.com"))
    
        @test length(findMany(User; query=Dict("where"=>Dict("name"=>Dict("contains"=>"ap"))))) == 2
        @test length(findMany(User; query=Dict("where"=>Dict("name"=>Dict("startsWith"=>"ap"))))) == 2
        @test length(findMany(User; query=Dict("where"=>Dict("name"=>Dict("endsWith"=>"ana"))))) == 1
        @test length(findMany(User; query=Dict("where"=>Dict("name"=>Dict("in"=>["apple","banana"])))) ) == 2
        @test length(findMany(User; query=Dict("where"=>Dict("name"=>Dict("notIn"=>["apple","banana"])))) ) == 1
        @test length(findMany(User; query=Dict("where"=>Dict("NOT"=> Dict("name"=>"apple"))))) == 2
        @test length(findMany(User; query=Dict("where"=>Dict("OR"=>[Dict("name"=>"apple"),Dict("name"=>"banana")])))) == 2
    end
    
    @testset "OrionORM Include edge cases" begin
        deleteMany(Post, Dict("where"=>Dict()), forceDelete=true)
        deleteMany(User, Dict("where"=>Dict()), forceDelete=true)
    
        u = create(User, Dict("name"=>"nopost","email"=>"nopost@e.com"))
        res = findMany(User; query=Dict("where"=>Dict("name"=>"nopost"), "include"=>[Post]))
        @test length(res) == 1
        @test length(res[1]["Post"]) == 0
    end
    
    @testset "OrionORM Default timestamp" begin
        deleteMany(Post, Dict("where"=>Dict()), forceDelete=true)
        deleteMany(User, Dict("where"=>Dict()), forceDelete=true)
    
        u = create(User, Dict("name"=>"u","email"=>"u@e.com"))
        p = create(Post, Dict("title"=>"t","authorId"=>u.id))
        @test isa(p.createdAt, DateTime)
        @test p.createdAt > Dates.now() - Dates.Millisecond(5000)
    end
    
    @testset "OrionORM updateMany" begin
        deleteMany(User, Dict("where"=>Dict()), forceDelete=true)
        data = [Dict("name"=>"A$i","email"=>"a$(i)@e.com") for i in 1:3]
    
        result = createMany(User, data)
        @test result == true
        insertedData = findMany(User; query=Dict("where"=>Dict("name"=>Dict("startsWith"=>"A"))))
        @test length(insertedData) == 3
    
        updated = updateMany(User, Dict("where"=>Dict("name"=>"A1")), Dict("name"=>"AX"))
        @test length(updated) == 1
        @test updated[1].name == "AX"
    end
    
    @testset "OrionORM Transaction rollback" begin
        deleteMany(User, Dict("where"=>Dict()), forceDelete=true)
        user = create(User, Dict("name"=>"T","email"=>"t@e.com"))
    
        conn = dbConnection()
        try
            begin
                @test_throws ErrorException DBInterface.transaction(conn) do
                    OrionORM.executeQuery(conn, "UPDATE User SET name = ? WHERE id = ?", ["X", user.id]; useTransaction=false)
                    error("fail")
                end
            end
        finally
            releaseConnection(conn)
        end
    
        found = findFirst(User; query=Dict("where"=>Dict("id"=>user.id)))
        @test found.name == "T"
    end
   
    @testset "OrionORM findUnique without throw" begin
        @test isnothing(findUnique(User, "email", "notfound@none.com")) 
    end    
end


# # Benchmark de INSERTs utilizando @benchmark macro com criação de dados para insert
# insert_bench = @benchmark begin
#     userData = Dict("name" => "Benchmark User", "email" => randstring(25) * "@example.com", "cpf" => "12345678900")
#     create(User, userData)
# end

# # Benchmark createMany
# insert_many_bench = @benchmark begin
#     userData = [Dict("name" => "Benchmark User $(i)", "email" => "benchmark$(i)@example.com", "cpf" => "12345678900") for i in 1:100]
#     createMany(User, userData)
# end

# # Benchmark de SELECTs utilizando @benchmark macro
# select_bench = @benchmark begin
#     findFirst(User; query=Dict("where" => Dict("email" => "benchmark@example.com")))
# end
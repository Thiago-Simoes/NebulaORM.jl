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

function exec!(conn, sql, params=Any[])
    OrionORM.executeQuery(conn, sql, params; useTransaction=false)
end

function recreate_with_raw_sql!() # Simulate a database with a known schema
    conn = dbConnection()
    try
        exec!(conn, "DROP TABLE IF EXISTS `post`")
        exec!(conn, "DROP TABLE IF EXISTS `user`")

        exec!(conn, """
            CREATE TABLE `user` (
              `id` INT NOT NULL AUTO_INCREMENT,
              `name` VARCHAR(50) NOT NULL,
              `email` VARCHAR(200) NOT NULL,
              PRIMARY KEY (`id`),
              UNIQUE KEY `ux_user_email` (`email`),
              KEY `ix_user_id_name` (`id`,`name`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        """)

        exec!(conn, """
            CREATE TABLE `post` (
              `id` INT NOT NULL AUTO_INCREMENT,
              `title` TEXT NOT NULL,
              `authorId` INT NOT NULL,
              `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP(),
              PRIMARY KEY (`id`),
              KEY `ix_post_author` (`authorId`),
              CONSTRAINT `fk_post_author`
                FOREIGN KEY (`authorId`) REFERENCES `user`(`id`)
                ON UPDATE CASCADE ON DELETE RESTRICT
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        """)
    finally
        releaseConnection(conn)
    end
end


recreate_with_raw_sql!()

@testset verbose = true "OrionORM" begin
    @testset "Schema Introspection" begin
        schema = generateModels()  # Generate the schema from the database
        @test length(schema) > 0

        # Clean database state and re-run migration
        exec!(dbConnection(), "DROP TABLE IF EXISTS `post`")
        exec!(dbConnection(), "DROP TABLE IF EXISTS `user`")
        resetORM!()
        
        tWrapped = "begin\n$(schema)\nend"
        eval(Meta.parse(tWrapped))
    end

    @testset "Basic CRUD Tests" begin
        userData = Dict("name" => "Thiago", "email" => "thiago@example.com", "cpf" => "00000000000")
        userSelected = create(user, userData)
        @test userSelected.name == "Thiago"
        @test userSelected.email == "thiago@example.com"
        @test hasproperty(userSelected, :id) 

        foundUser = findFirst(user; query=Dict("where" => Dict("name" => "Thiago")))
        @test foundUser !== nothing
        @test foundUser.id == userSelected.id

        updatedUser = update(user, Dict("where" => Dict("id" => userSelected.id)), Dict("name" => "Thiago Updated"))
        @test updatedUser.name == "Thiago Updated"

        upsertUser = upsert(user, "email", "thiago@example.com",
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
        createdRecords = createMany(user, records)
        @test createdRecords == true

        manyUsers = findMany(user)
        @test length(manyUsers) ≥ 2

        uMany = updateMany(user, Dict("where" => Dict("name" => "Bob")), Dict("name" => "Bob Updated"))
        
        for u in uMany
            @test u.name == "Bob Updated"
        end

        userData = Dict("name" => "Thiago", "email" => "thiago@example.com", "cpf" => "00000000000")
        userSelected = create(user, userData)
        postData = Dict("title" => "My First post", "authorId" => userSelected.id)
        postSelected = create(post, postData)
        @test postSelected.title == "My First post"
        @test postSelected.authorId == userSelected.id

        @test hasMany(userSelected, post, "authorId")[1].title == "My First post"

        @test_throws ErrorException deleteMany(user, Dict("where" => Dict()))
        deleteManyResult = deleteMany(user, Dict("where" => Dict()), forceDelete=true)
        @test deleteManyResult === true
    end

    @testset "Relationships Tests" begin
        userData = Dict("name" => "Thiago", "email" => "thiago@example.com", "cpf" => "00000000000")
        userSelected = create(user, userData)

        foundUser = findFirst(user; query=Dict("where" => Dict("name" => "Thiago")))

        postData = Dict("title" => "My First post", "authorId" => userSelected.id)
        postSelected = create(post, postData)

        userWithPosts = findFirst(user; query=Dict("where" => Dict("name" => "Thiago"), "include" => [post]))
        @test length(userWithPosts["post"]) == 1
        @test typeof(userWithPosts["post"][1]) <: post
        @test userWithPosts["post"][1].title == "My First post"
        @test userWithPosts["post"][1].authorId == userSelected.id

    end

    @testset "Pagination Tests" begin
        deleteMany(user, Dict("where" => Dict()), forceDelete=true)

        usersData = [ Dict("name" => "user $(i)", "email" => "userSelected$(i)@example.com", "cpf" => string(1000 + i)) for i in 1:5 ]
        createdUsers = createMany(user, usersData)
        @test createdUsers == true
        @test length(findMany(user)) == 5  

        page1 = findMany(user; query=Dict("limit" => 2, "offset" => 0, "orderBy" => Dict("id" => "ASC")))
        @test length(page1) == 2
        @test page1[1].name == "user 1"
        @test page1[2].name == "user 2"

        page1rev = findMany(user; query=Dict("limit" => 2, "offset" => 0, "orderBy" => Dict("id" => "DESC")))
        @test length(page1rev) == 2
        @test page1rev[1].name == "user 5"
        @test page1rev[2].name == "user 4"

        page2 = findMany(user; query=Dict("limit" => 2, "offset" => 2, "orderBy" => Dict("id" => "ASC")))
        @test length(page2) == 2
        @test page2[1].name == "user 3"
        @test page2[2].name == "user 4"

        page3 = findMany(user; query=Dict("limit" => 2, "offset" => 4, "orderBy" => Dict("id" => "ASC")))
        @test length(page3) == 1
        @test page3[1].name == "user 5"
    end

    @testset "Bulk Operations & Benchmarks" begin
        deleteMany(user, Dict("where" => Dict()), forceDelete=true)
    
        N = 100
        user_payloads = [Dict("name" => "BenchUser$(i)",
                              "email" => "bench$(i)@example.com") for i in 1:N]
    
        t_insert = @elapsed for payload in user_payloads
            create(user, payload)
        end
        @info "100 inserts sequenciais em $(t_insert) segundos"
    
        @test length(findMany(user)) == N
    
        t_select = @elapsed for _ in 1:N
            idx = rand(1:N)
            findFirst(user; query=Dict("where" => Dict("email" => "bench$(idx)@example.com")))
        end
        @info "100 selects sequenciais em $(t_select) segundos"
    
        sample = findFirst(user; query=Dict("where" => Dict("email" => "bench1@example.com")))
        @test sample !== nothing && sample.email == "bench1@example.com"
    end

    @testset "Error handling" begin
        @test_throws ErrorException update(user, Dict(), Dict("name"=>"x"))
        @test_throws ErrorException delete(user, Dict())
    end
    
    @testset "QueryBuilder operators" begin
        deleteMany(user, Dict("where"=>Dict()), forceDelete=true)
        create(user, Dict("name"=>"apple","email"=>"apple@e.com"))
        create(user, Dict("name"=>"banana","email"=>"banana@e.com"))
        create(user, Dict("name"=>"apricot","email"=>"apricot@e.com"))
    
        @test length(findMany(user; query=Dict("where"=>Dict("name"=>Dict("contains"=>"ap"))))) == 2
        @test length(findMany(user; query=Dict("where"=>Dict("name"=>Dict("startsWith"=>"ap"))))) == 2
        @test length(findMany(user; query=Dict("where"=>Dict("name"=>Dict("endsWith"=>"ana"))))) == 1
        @test length(findMany(user; query=Dict("where"=>Dict("name"=>Dict("in"=>["apple","banana"])))) ) == 2
        @test length(findMany(user; query=Dict("where"=>Dict("name"=>Dict("notIn"=>["apple","banana"])))) ) == 1
        @test length(findMany(user; query=Dict("where"=>Dict("NOT"=> Dict("name"=>"apple"))))) == 2
        @test length(findMany(user; query=Dict("where"=>Dict("OR"=>[Dict("name"=>"apple"),Dict("name"=>"banana")])))) == 2
    end
    
    @testset "Include edge cases" begin
        deleteMany(post, Dict("where"=>Dict()), forceDelete=true)
        deleteMany(user, Dict("where"=>Dict()), forceDelete=true)
    
        u = create(user, Dict("name"=>"nopost","email"=>"nopost@e.com"))
        res = findMany(user; query=Dict("where"=>Dict("name"=>"nopost"), "include"=>[post]))
        @test length(res) == 1
        @test length(res[1]["post"]) == 0
    end
    
    @testset "Default timestamp" begin
        deleteMany(post, Dict("where"=>Dict()), forceDelete=true)
        deleteMany(user, Dict("where"=>Dict()), forceDelete=true)
    
        u = create(user, Dict("name"=>"u","email"=>"u@e.com"))
        p = create(post, Dict("title"=>"t","authorId"=>u.id))
        @test isa(p.createdAt, DateTime)
        @test p.createdAt > Dates.now() - Dates.Millisecond(5000)
    end
    
    @testset "updateMany" begin
        deleteMany(user, Dict("where"=>Dict()), forceDelete=true)
        data = [Dict("name"=>"A$i","email"=>"a$(i)@e.com") for i in 1:3]
    
        result = createMany(user, data)
        @test result == true
        insertedData = findMany(user; query=Dict("where"=>Dict("name"=>Dict("startsWith"=>"A"))))
        @test length(insertedData) == 3
    
        updated = updateMany(user, Dict("where"=>Dict("name"=>"A1")), Dict("name"=>"AX"))
        @test length(updated) == 1
        @test updated[1].name == "AX"
    end
    
    @testset "Transaction rollback" begin
        deleteMany(user, Dict("where"=>Dict()), forceDelete=true)
        userSelected = create(user, Dict("name"=>"T","email"=>"t@e.com"))
    
        conn = dbConnection()
        try
            begin
                @test_throws ErrorException DBInterface.transaction(conn) do
                    OrionORM.executeQuery(conn, "UPDATE user SET name = ? WHERE id = ?", ["X", userSelected.id]; useTransaction=false)
                    error("fail")
                end
            end
        finally
            releaseConnection(conn)
        end
    
        found = findFirst(user; query=Dict("where"=>Dict("id"=>userSelected.id)))
        @test found.name == "T"
    end
   
    @testset "findUnique without throw" begin
        @test isnothing(findUnique(user, "email", "notfound@none.com")) 
    end    
end


# # Benchmark de INSERTs utilizando @benchmark macro com criação de dados para insert
# insert_bench = @benchmark begin
#     userData = Dict("name" => "Benchmark user", "email" => randstring(25) * "@example.com", "cpf" => "12345678900")
#     create(user, userData)
# end

# # Benchmark createMany
# insert_many_bench = @benchmark begin
#     userData = [Dict("name" => "Benchmark user $(i)", "email" => "benchmark$(i)@example.com", "cpf" => "12345678900") for i in 1:100]
#     createMany(user, userData)
# end

# # Benchmark de SELECTs utilizando @benchmark macro
# select_bench = @benchmark begin
#     findFirst(user; query=Dict("where" => Dict("email" => "benchmark@example.com")))
# end
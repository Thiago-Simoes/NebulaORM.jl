# /test/benchmark/include_benchmark.jl
using BenchmarkTools
using Random
using Dates
using OrionORM   # garantir que o pacote esteja usando o mesmo db/.env dos testes
using DBInterface

# ===========================================
# CONFIG
# ===========================================
const PAGE_SIZES   = [50, 200, 1000]           # tamanhos de página para comparar
const POSTS_PER_U  = 10                         # posts por usuário no seed
const WITH_PROFILE = true                       # se cria profile 1:1

# Se quiser testar chunks distintos, ajuste a função no OrionORM (se expor ENV) e rode em loop.

# ===========================================
# Helpers de instrumentação (contagem de queries)
# ===========================================
const QUERY_COUNTER = Ref(0)

OrionORM.setOnQuery!((sql, params, meta)->(QUERY_COUNTER[] += 1))
reset_query_counter() = (QUERY_COUNTER[] = 0)
num_queries() = QUERY_COUNTER[]


# ===========================================
# MODELOS DE EXEMPLO (ajuste se já existirem)
# Esperado:
#   User(id PK AI, name, email)
#   Post(id PK AI, user_id FK -> User.id, title)
#   Profile(id PK AI, user_id FK -> User.id, phone)
# ===========================================
# Se você já tem esses Models definidos no bootstrap dos testes, pode pular esta seção.
function define_models()
    Model(:User, [
        ("id",        INTEGER(), [PrimaryKey(), AutoIncrement()]),
        ("name",      VARCHAR(100), [NotNull()]),
        ("email",     VARCHAR(150), [NotNull(), Unique()])
    ], [], [ ["email"] ])

    Model(:Post, [
        ("id",       INTEGER(), [PrimaryKey(), AutoIncrement()]),
        ("user_id",  INTEGER(), [NotNull()]),
        ("title",    VARCHAR(200), [NotNull()]),
    ], [
        # belongsTo: Post.user_id -> User.id  (gera hasMany reverso em User)
        (:user_id, :User, "id", :belongsTo)
    ])

    Model(:Profile, [
        ("id",       INTEGER(), [PrimaryKey(), AutoIncrement()]),
        ("user_id",  INTEGER(), [NotNull()]),
        ("phone",    VARCHAR(50), [NotNull()]),
    ], [
        # belongsTo: Profile.user_id -> User.id  (gera hasMany reverso, mas usaremos como hasOne semanticamente)
        (:user_id, :User, "id", :belongsTo)
    ])

    true
end

# ===========================================
# SEED (gera N usuários com posts e profiles)
# ===========================================
function seed_data!(n_users::Int64; posts_per_user::Int64=POSTS_PER_U, with_profile::Bool=WITH_PROFILE)
    define_models()

    # limpa tabelas (ordem: filhos antes dos pais)
    deleteMany(Post, Dict("where"=>Dict("id"=>Dict("gt"=>0))); forceDelete=true)
    deleteMany(Profile, Dict("where"=>Dict("id"=>Dict("gt"=>0))); forceDelete=true)
    deleteMany(User, Dict("where"=>Dict("id"=>Dict("gt"=>0))); forceDelete=true)

    # cria usuários em lote
    users_batch = [ Dict(
        "name"  => "User $(i)",
        "email" => "user$(i)@example.com"
    ) for i in 1:n_users ]
    createMany(User, users_batch; chunkSize=1000, transaction=true)

    # pega ids dos usuários recém criados
    base = findMany(User; query=Dict("orderBy"=>Dict("id"=>"asc"), "limit"=>n_users))
    user_ids = [u.id for u in base]

    # cria posts em lote
    posts = Vector{Dict{String,Any}}()
    for uid in user_ids
        for j in 1:posts_per_user
            push!(posts, Dict(
                "user_id" => uid,
                "title"   => "Post $(j) of user $(uid)"
            ))
        end
    end
    !isempty(posts) && createMany(Post, posts; chunkSize=1000, transaction=true)

    # cria profiles (1:1) se habilitado
    if with_profile
        profs = [ Dict("user_id"=>uid, "phone"=>"(21) 9$(rand(10000000:99999999))")
                  for uid in user_ids ]
        !isempty(profs) && createMany(Profile, profs; chunkSize=1000, transaction=true)
    end
end

# ===========================================
# CENÁRIOS DE BENCHMARK
# ===========================================
function bench_scenarios()

    for page in PAGE_SIZES
        println("---- Page size = $page ----")

        # 1) Sem include (baseline)
        reset_query_counter()
        q = Dict("orderBy"=>Dict("id"=>"asc"), "limit"=>page, "offset"=>0)
        @show num_queries()
        @time OrionORM.findMany(User; query=q)
        println("queries (no include) = $(num_queries())")
        @btime OrionORM.findMany(User; query=$q)

        # 2) include hasMany: Posts
        reset_query_counter()
        q_posts = Dict("orderBy"=>Dict("id"=>"asc"), "limit"=>page, "offset"=>0, "include"=>[Post])
        @time OrionORM.findMany(User; query=q_posts)
        println("queries (include Posts) = $(num_queries())")
        @btime OrionORM.findMany(User; query=$q_posts)
        # Esperado: ~ 1 (base) + ceil(page/chunk)  (com chunk default ~1000 => ≈2 para page=1000)

        # 3) include belongsTo/hasOne: Profile
        reset_query_counter()
        q_prof = Dict("orderBy"=>Dict("id"=>"asc"), "limit"=>page, "offset"=>0, "include"=>[Profile])
        @time OrionORM.findMany(User; query=q_prof)
        println("queries (include Profile) = $(num_queries())")
        @btime OrionORM.findMany(User; query=$q_prof)

        # 4) include ambos: Posts + Profile
        reset_query_counter()
        q_both = Dict("orderBy"=>Dict("id"=>"asc"), "limit"=>page, "offset"=>0, "include"=>[Post,Profile])
        @time OrionORM.findMany(User; query=q_both)
        println("queries (include Posts+Profile) = $(num_queries())")
        @btime OrionORM.findMany(User; query=$q_both)

        println()
    end
end

# ===========================================
# RODAR
# Ajuste o número total de usuários para calibrar volume
# ===========================================
function main()
    # Sugestão: rode duas vezes (warmup + medição)
    println("\n===> Seeding with $n_users users, $POSTS_PER_U posts/user, profile=$(WITH_PROFILE)\n")
    seed_data!(n_users)
    bench_scenarios()   # 5k usuários * 10 posts = 50k posts
    # bench_scenarios(20_000)  # se quiser estressar
end

main()

# If you want to reset the ORM state (models, relationships, indexes) after the benchmark, uncomment:
# OrionORM.resetORM!()


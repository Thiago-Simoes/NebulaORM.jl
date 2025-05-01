import Pkg
Pkg.activate(".")
using Documenter, NebulaORM

push!(LOAD_PATH,"../src/")
makedocs(
    sitename="NebulaORM.jl",
    modules=[NebulaORM],
    pages = [
    "Home" => "index.md",
    "Manual" => ["manual/start.md", "manual/relationship.md"],
    "Reference" => ["Reference/API.md"]
    ]
)

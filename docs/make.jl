import Pkg
Pkg.activate(".")
using Documenter, OrionORM

push!(LOAD_PATH,"../src/")
makedocs(
    sitename="OrionORM.jl",
    modules=[OrionORM],
    pages = [
    "Home" => "index.md",
    "Manual" => ["manual/start.md", "manual/relationship.md"],
    "Reference" => ["Reference/API.md"]
    ]
)

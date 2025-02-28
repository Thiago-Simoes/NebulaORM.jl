import Pkg
Pkg.activate(".")
using Documenter, Nebula

push!(LOAD_PATH,"../src/")
makedocs(
    sitename="Nebula.jl",
    modules=[Nebula],
    pages = [
    "Home" => "index.md",
    "Manual" => ["manual/start.md", "manual/relationship.md"],
    "Reference" => ["Reference/API.md"]
    ]
)

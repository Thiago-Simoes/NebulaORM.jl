using Documenter, ORM

push!(LOAD_PATH,"../src/")
makedocs(
    sitename="ORM.jl",
    modules=[ORM],
    pages = [
    "Home" => "index.md",
    "Manual" => ["manual/start.md"],
    "Reference" => ["Reference/API.md"]
    ]
)

import Pkg
Pkg.activate(".")
using Documenter, OrionORM

push!(LOAD_PATH,"../src/")
makedocs(
  sitename="OrionORM.jl",
  modules=[OrionORM],
  pages=[
    "Home"       => "index.md",
    "Quickstart" => "manual/start.md",
    "QueryBuilder"   => "manual/querybuilder.md",
    "Transactions"   => "manual/transactions.md",
    "Bulk Operations"=> "manual/bulk.md",
    "Configuration"  => "manual/configuration.md",
    "Error Handling" => "manual/errors.md",
    "Examples & FAQ" => "manual/examples.md",
    "Reference"      => ["Reference/API.md","Reference/relationship.md"]
  ]
)

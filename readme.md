# Nebula.jl

## Objective

This project aims to provide a modern, complete, and robust ORM for Julia.  
**Security note:** It is not production-ready yet.


## Installation

The package can be installed with the Julia package manager.
From the Julia REPL, type `]` to enter the Pkg REPL mode and run:

```
pkg> add ORM
```

Or, equivalently, via the `Pkg` API:

```julia
julia> import Pkg; Pkg.add("ORM")
```

## Documentation

- [**STABLE**](https://thiago-simoes.github.io/ORM.jl/) &mdash; **documentation of the most recently tagged version.**

## Project Status

The package is tested against, and being developed for, Julia `1.6` and above on Linux, macOS, and Windows.


## Collaboration

Contributions are welcome!  
Feel free to open pull requests or issues with suggestions and enhancements.

## Vulnerabilities

If you discover any **vulnerabilities**, please report them via issues.


### How to build docs?
$ julia --project make.jl

## License
JuliaWebSession is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

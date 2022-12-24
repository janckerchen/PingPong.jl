import Pkg;
let dse =  "~/.julia/environments/$(VERSION)/"
    if dse ∉ LOAD_PATH
        push!(LOAD_PATH, dse)
    end
end
using Documenter, DocStringExtensions

# Modules
using Backtest
using Pbar
project_path = Pkg.project().path |> dirname
function use(name, args...)
    path = joinpath(project_path, args...)
    if endswith(args[end], ".jl")
        include(path)
        @eval using .$name
    else
        path ∉ LOAD_PATH && push!(LOAD_PATH, path)
        @eval using $name
    end
end
use(:Prices, "Data", "src", "prices.jl")
use(:Fetch, "Exchanges", "Fetch")
use(:Short, "Analysis", "Mark", "Short")
use(:Long, "Analysis", "Mark", "Long")
use(:MVP, "Analysis", "Mark", "MVP")
use(:Processing, "Analysis", "Processing")
use(:Pairs, "Pairs")

makedocs(sitename="JuBot.jl")

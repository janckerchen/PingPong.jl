module Stats
occursin(string(@__MODULE__), get(ENV, "JULIA_NOPRECOMP", "")) && __precompile__(false)

using Strategies: Strategies as st, Strategy
using Processing: normalize!, resample
using Instances
using OrderTypes

using Data
using Data.DFUtils
using Data.DataFramesMeta
using Data.DataFrames

using TimeTicks
using Lang
using Statistics
using Statistics: median

include("trades_resample.jl")
include("trades_balance.jl")

end # module Stats

using Engine.Strategies: Strategies as st, Strategy
using Processing: normalize!, resample
using Engine.Instances
using Engine.OrderTypes

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
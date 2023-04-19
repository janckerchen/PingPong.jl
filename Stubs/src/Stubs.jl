module Stubs

using Engine.Exchanges: Exchanges as exs, Instruments as im
using Engine: SimMode
using Engine.TimeTicks
using Engine.Misc
using Engine.Simulations: Simulations as sim
using Engine.Strategies
using Data: Data as da
using Data.DataFrames: DataFrame
using Data: Cache as ca
import Data: stub!
using CSV: CSV as CSV
using Pkg: Pkg
using Lang

const PROJECT_PATH = dirname(@something Base.ACTIVE_PROJECT[] Pkg.project().path)
const OHLCV_FILE_PATH = joinpath(PROJECT_PATH, "test", "stubs", "ohlcv.csv")

read_ohlcv() = CSV.read(OHLCV_FILE_PATH, DataFrame)

function remove_loadpath!(path)
    try
        deleteat!(findfirst(x -> x == "Instances", LOAD_PATH), LOAD_PATH)
    catch
    end
end

function stubscache_path()
    proj = Pkg.project()
    @assert proj.name == "PingPong"
    joinpath(dirname(proj.path), "test", "stubs")
end

function save_stubtrades(ai)
    ca.save_cache("trades_stub_$(ai.asset.bc).jls", ai.history; cache_path=stubscache_path())
end

# Strategy can't be saved because it has a module property and modules can't be deserialized
# function save_strategy(s)
#     ca.save_cache("strategy_stub_$(nameof(s))", s; cache_path=stubscache_path())
# end
# function load_strategy(name)
#     ca.load_cache("strategy_stub_$(name)"; cache_path=stubscache_path())
# end

function load_stubtrades(ai)
    ca.load_cache("trades_stub_$(ai.asset.bc).jls"; cache_path=stubscache_path())
end

function load_stubtrades!(ai)
    trades = load_stubtrades(ai)
    append!(ai.history, trades)
end

@doc "Generates trades and saves them to the stubs shed."
function gensave_trades(n=10_000, s=Strategies.strategy(:Example); dosave=true)
    try
        for ai in s.universe
            da.stub!(ai, n)
        end
        SimMode.backtest!(s)
        if dosave
            for ai in s.universe
                save_stubtrades(ai)
            end
        end
    finally
        remove_loadpath!("OrderTypes")
    end
end

function stub!(s::Strategy, n=10_000)
    for ai in s.universe
        sim.stub!(ai, n)
    end
    for ai in s.universe
        load_stubtrades!(ai)
    end
    s
end

include("../../test/stubs/Example.jl")
function stub_strategy(mod=nothing, args...; dostub=true, cfg=nothing, kwargs...)
    isnothing(cfg) && (cfg = Misc.Config())
    if isnothing(mod)
        ppath = dirname(Pkg.project().path)
        cfg.attrs["include_file"] = realpath(joinpath(ppath, "test/stubs/Example.jl"))
        mod = Example
    end
    s = Strategies.strategy!(mod, cfg, args...; kwargs...)
    dostub && stub!(s)
    s
end

@preset let
    @precomp let
        s = stub_strategy()
        gensave_trades(s; dosave=false)
    end
end

end

using TimeTicks
using ExchangeTypes
using ExchangeTypes: exc
using Data: Data, load, zi, empty_ohlcv, DataFrame, DataStructures
using Data.DFUtils: daterange, timeframe
using .DataStructures: SortedDict
using Instruments: Instruments, compactnum, AbstractAsset, Cash
import Instruments: _hashtuple
using Misc: config
using OrderTypes
import Data: stub!

const MM = NamedTuple{(:min, :max),Tuple{Float64,Float64}}
const Limits = NamedTuple{(:leverage, :amount, :price, :cost),NTuple{4,MM}}
const Precision = NamedTuple{(:amount, :price),Tuple{Real,Real}}
const Fees = NamedTuple{(:taker, :maker, :min, :max),NTuple{4,Real}}

@doc "An asset instance holds all known state about an asset, i.e. `BTC/USDT`:
- `asset`: the identifier
- `data`: ohlcv series
- `history`: the trade history of the pair
- `cash`: how much is currently held, can be positive or negative (short)
- `exchange`: the exchange instance that this asset instance belongs to.
- `limits`: minimum order size (from exchange)
- `precision`: number of decimal points (from exchange)
"
struct AssetInstance50{T<:AbstractAsset,E<:ExchangeID}
    asset::T
    data::SortedDict{TimeFrame,DataFrame}
    history::Vector{Trade{O,T,E} where O<:OrderType}
    cash::Cash{S1,Float64} where {S1}
    cash_committed::Cash{S2,Float64} where {S2}
    exchange::Exchange{E}
    limits::Limits
    precision::Precision
    fees::Fees
    function AssetInstance50(
        a::A, data, e::Exchange{E}; limits, precision, fees
    ) where {A<:AbstractAsset,E<:ExchangeID}
        new{A,E}(
            a,
            data,
            Trade{OrderType,A,E}[],
            Cash{a.bc,Float64}(0.0),
            Cash{a.bc,Float64}(0.0),
            e,
            limits,
            precision,
            fees,
        )
    end
end
AssetInstance = AssetInstance50

_hashtuple(ai::AssetInstance) = (Instruments._hashtuple(ai.asset)..., ai.exchange.id)
Base.hash(ai::AssetInstance) = hash(_hashtuple(ai))
Base.hash(ai::AssetInstance, h::UInt) = hash(_hashtuple(ai), h)
Base.propertynames(::AssetInstance) = (fieldnames(AssetInstance)..., :ohlcv)
Base.Broadcast.broadcastable(s::AssetInstance) = Ref(s)

function instance(exc::Exchange, a::AbstractAsset)
    data = Dict()
    @assert a.raw ∈ keys(exc.markets) "Market $(a.raw) not found on exchange $(exc.name)."
    for tf in config.timeframes
        data[tf] = load(zi, exc.name, a.raw, string(tf))
    end
    AssetInstance(a, data, exc)
end
instance(a) = instance(exc, a)

@doc "Load ohlcv data of asset instance."
function load!(a::AssetInstance; reset=true)
    for (tf, df) in a.data
        reset && empty!(df)
        loaded = load(zi, a.exchange.name, a.raw, string(tf))
        append!(df, loaded)
    end
end
Base.getproperty(a::AssetInstance, f::Symbol) = begin
    if f == :ohlcv
        first(getfield(a, :data)).second
    elseif f == :bc
        a.asset.bc
    elseif f == :qc
        a.asset.qc
    else
        getfield(a, f)
    end
end

@doc "Get the last available candle strictly lower than `apply(tf, date)`"
function Data.candlelast(ai::AssetInstance, tf::TimeFrame, date::DateTime)
    Data.candlelast(ai.data[tf], tf, date)
end

function Data.candlelast(ai::AssetInstance, date::DateTime)
    tf = first(keys(ai.data))
    Data.candlelast(ai, tf, date)
end


function OrderTypes.Order(ai::AssetInstance, type; kwargs...)
    Order(ai.asset, ai.exchange.id, type; kwargs...)
end

@doc "Returns a similar asset instance with cash and orders reset."
function Base.similar(ai::AssetInstance)
    AssetInstance(
        ai.asset,
        ai.data,
        ai.exchange;
        limits=ai.limits,
        precision=ai.precision,
        fees=ai.fees,
    )
end

Instruments.cash!(ai::AssetInstance, v) = cash!(ai.cash, v)
Instruments.add!(ai::AssetInstance, v) = add!(ai.cash, v)
Instruments.sub!(ai::AssetInstance, v) = sub!(ai.cash, v)
freecash(ai::AssetInstance) = ai.cash - ai.cash_committed
Data.DFUtils.firstdate(ai::AssetInstance) = first(ai.ohlcv.timestamp)
Data.DFUtils.lastdate(ai::AssetInstance) = last(ai.ohlcv.timestamp)

function Base.string(ai::AssetInstance)
    "AssetInstance($(ai.bc)/$(ai.qc)[$(compactnum(ai.cash.value))]{$(ai.exchange.name)})"
end
Base.show(io::IO, ai::AssetInstance) = write(io, string(ai))
stub!(ai::AssetInstance, df::DataFrame) = begin
    tf = timeframe!(df)
    ai.data[tf] = df
end
takerfees(ai::AssetInstance) = ai.fees.taker
makerfees(ai::AssetInstance) = ai.fees.maker
minfees(ai::AssetInstance) = ai.fees.min
maxfees(ai::AssetInstance) = ai.fees.max

export AssetInstance, instance, load!
export takerfees, makerfees, maxfees, minfees
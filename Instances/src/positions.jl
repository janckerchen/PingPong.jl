using Misc: MVector, MarginMode
using Instruments.Derivatives: Derivative
using Exchanges: LeverageTiersDict, leverage_tiers
import Exchanges: maxleverage, tier

abstract type PositionSide end
struct Long <: PositionSide end
struct Short <: PositionSide end

PositionSide(::Type{Buy}) = Long
PositionSide(::Type{Sell}) = Short
PositionSide(::Order{OrderType{Buy}}) = Long
PositionSide(::Order{OrderType{Sell}}) = Short

const OneVec = MVector{1,T} where {T<:Union{DateTime,Real}}
@enum PositionStatus OpenPosition ClosedPosition

@doc "A position tracks the margin state of an asset instance:
- `timestamp`: last update time of the position (`DateTime`)
- `side`: the side of the position `<:PositionSide` `Long` or `Short`
- `tiers`: sorted dict of all the leverage tiers
For the rest of the fields refer to  [ccxt docs](https://docs.ccxt.com/#/README?id=position-structure)
"
@kwdef struct Position{S<:PositionSide,M<:MarginMode}
    status::MVector{1,PositionStatus} = MVector(ClosedPosition)
    asset::Derivative
    timestamp::OneVec = OneVec(DateTime(0))
    liquidation_price::OneVec = OneVec(0.0)
    entryprice::OneVec = OneVec(0.0)
    maintenance_margin::OneVec = OneVec(0.0)
    initial_margin::OneVec = OneVec(0.0)
    notional::OneVec = OneVec(0.0)
    leverage::OneVec = OneVec(0.0)
    min_size::T where {T<:Real}
    tiers::LeverageTiersDict
end

function Position{S,M}(
    asset::Derivative, exc::Exchange; min_size, kwargs...
) where {S<:PositionSide,M<:MarginMode}
    Position{S,M}(; asset, min_size)
end

const LongPosition{M} = Position{Long,M} where {M<:MarginMode}
const ShortPosition{M} = Position{Short,M} where {M<:MarginMode}

maxleverage(po::Position, size::Real) = maxleverage(po.tiers, size)

close_position!(po::Position) = begin
    @assert po.status[] == OpenPosition
    po.status[] = ClosedPosition
end

open_position!(po::Position) = begin
    @assert po.status[] == ClosedPosition
    po.status[] = OpenPosition
end

Base.isopen(po::Position) = po.status[] == OpenPosition
islong(::Position{<:Long}) = true
isshort(::Position{<:Short}) = true
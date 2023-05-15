using OrderTypes.ExchangeTypes: ExchangeID
using OrderTypes: PositionSide, PositionTrade, LiquidationType
using Strategies.Instruments.Derivatives: Derivative
using Executors.Instances: leverage_tiers, tier, position
import Executors.Instances: Position, MarginInstance
using Executors: withtrade!, maintenance!, orders, isliquidatable
using Strategies: IsolatedStrategy, MarginStrategy, exchangeid
using .Instances: PositionOpen, PositionUpdate, PositionClose
using .Instances: margin, maintenance, status, posside
using Misc: DFT

function open_position!(
    s::IsolatedStrategy{Sim}, ai::MarginInstance, t::PositionTrade{P};
) where {P<:PositionSide}
    # NOTE: Order of calls is important
    po = position(ai, P)
    @deassert cash(ai, opposite(P())) == 0.0 (cash(ai, opposite(P()))),
    status(ai, opposite(P()))
    @deassert !isopen(po)
    @deassert notional(po) == 0.0
    # Cash should already be updated from trade construction
    @deassert cash(po) == cash(ai, P()) == t.amount
    withtrade!(po, t)
    # Notional should never be above the trade size
    # unless fees are negative
    @deassert notional(po) < abs(t.size) || minfees(ai) < 0.0
    # finalize
    status!(ai, P(), PositionOpen())
    @deassert status(po) == PositionOpen()
    @deassert ai in s.holdings
    ping!(s, ai, t, po, PositionOpen())
end

function update_position!(
    s::IsolatedStrategy{Sim}, ai, t::PositionTrade{P}
) where {P<:PositionSide}
    # NOTE: Order of calls is important
    po = position(ai, P)
    @deassert notional(po) != 0.0
    # Cash should already be updated from trade construction
    withtrade!(po, t)
    # position is still open
    ping!(s, ai, t, po, PositionUpdate())
end

function close_position!(s::IsolatedStrategy{Sim}, ai, p::PositionSide, date=nothing)
    # when a date is given we should close pending orders and sell remaining cash
    if !isnothing(date)
        for o in orders(s, ai, p)
            cancel!(s, o, ai; err=OrderCancelled(o))
        end
        @deassert iszero(committed(ai, p)) committed(ai, p)
        price = closeat(ai, date)
        amount = nondust(ai, price, p)
        if amount > 0.0
            o = _create_sim_market_order(
                s, MarketOrder{liqside(p)}, ai; amount, date, price
            )
            @deassert !isnothing(o) &&
                o.date == date &&
                isapprox(o.amount, amount; atol=ai.precision.amount)
            marketorder!(s, o, ai, amount; o.price, date)
        end
    end
    reset!(ai, p)
    delete!(s.holdings, ai)
    @deassert !isopen(position(ai, p)) && iszero(ai)
end

function update_margin!(pos::Position, qty::Real)
    p = posside(pos)
    price = entryprice(pos)
    lev = leverage(pos)
    size = notional(pos)
    prev_additional = margin(pos) - size / lev
    @deassert prev_additional >= 0.0 && qty >= 0.0
    additional = prev_additional + qty
    liqp = liqprice(p, price, lev, mmr(pos); additional, size)
    liqprice!(pos, liqp)
    # margin!(pos, )
end

@doc "Liquidates a position at a particular date.
`fees`: the fees for liquidating a position (usually higher than trading fees.)"
function liquidate!(
    s::MarginStrategy{Sim},
    ai::MarginInstance,
    p::PositionSide,
    date,
    fees=maxfees(ai) * 2.0,
)
    pos = position(ai, p)
    for o in orders(s, ai, p)
        cancel!(s, o, ai; err=LiquidationOverride(o, liqprice(pos), date, p))
    end
    amount = abs(pos.cash.value)
    price = liqprice(pos)
    o = _create_sim_market_order(
        s, LiquidationOrder{liqside(p),typeof(p)}, ai; amount, date, price
    )
    # The position might be too small to be tradeable, assume cash is lost
    isnothing(o) || begin
        t = marketorder!(s, o, ai, o.amount; o.price, date, fees)
        @deassert !isnothing(o) && o.date == date && 0.0 < abs(t.amount) <= abs(o.amount)
    end
    @deassert isdust(ai, price, p)
    close_position!(s, ai, p)
end

@doc "Checks asset positions for liquidations and executes them (Non hedged mode, so only the currently open position)."
function liquidation!(s::IsolatedStrategy{Sim}, ai::MarginInstance, date)
    pos = position(ai)
    isnothing(pos) && return nothing
    @deassert !isopen(opposite(ai, pos))
    p = posside(pos)()
    isliquidatable(ai, p, date) && liquidate!(s, ai, p, date)
end

@doc "Updates an isolated position in `Sim` mode from a new trade."
function position!(
    s::IsolatedStrategy{Sim}, ai::MarginInstance, t::PositionTrade{P};
) where {P<:PositionSide}
    @deassert exchangeid(s) == exchangeid(t)
    @deassert t.order.asset == ai.asset
    pos = position(ai, P)
    if isopen(pos)
        if isdust(ai, t.price, P())
            close_position!(s, ai, P())
        else
            @deassert !iszero(cash(pos)) || t isa ReduceTrade
            update_position!(s, ai, t)
        end
    else
        open_position!(s, ai, t)
    end
    liquidation!(s, ai, t.date)
end

@doc "Updates an isolated position in `Sim` mode from a new candle."
function position!(s::IsolatedStrategy{Sim}, ai, date::DateTime, po::Position=position(ai))
    # NOTE: Order of calls is important
    @deassert isopen(po)
    p = posside(po)()
    @deassert notional(po) != 0.0
    timestamp!(po, date)
    if isliquidatable(ai, p, date)
        liquidate!(s, ai, p, date)
    else
        # position is still open
        ping!(s, ai, date, po, PositionUpdate())
    end
end

function position!(s::IsolatedStrategy{Sim}, ai, date::DateTime, p::PositionSide)
    position!(s, ai, date, position(ai, p))
end
position!(::IsolatedStrategy{Sim}, ai, ::DateTime, ::Nothing) = nothing

@doc "Non margin strategies don't have positions."
position!(s::NoMarginStrategy, args...; kwargs...) = nothing
positions!(s::NoMarginStrategy{Sim}, args...; kwargs...) = nothing

@doc "Updates all open positions in a isolated (non hedged) strategy."
function positions!(s::IsolatedStrategy{Sim}, date::DateTime)
    for ai in s.holdings
        @deassert isopen(ai)
        position!(s, ai, date)
    end
    @ifdebug for ai in s.universe
        let po = position(ai)
            @assert ai ∈ s.holdings || isnothing(po) || !isopen(po)
        end
    end
end
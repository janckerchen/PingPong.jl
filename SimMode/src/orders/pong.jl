import Executors: pong!
using Executors
using Executors: iscommittable, priceat, marketorder, hold!
using OrderTypes: LimitOrderType, MarketOrderType
using Lang: @lget!, Option

@doc "Creates a simulated limit order."
function pong!(s::Strategy{Sim}, ai, t::Type{<:Order{<:LimitOrderType}}; amount, kwargs...)
    o = _create_sim_limit_order(s, t, ai; amount, kwargs...)
    isnothing(o) && return nothing
    limitorder_ifprice!(s, o, o.date, ai)
end

@doc "Creates a simulated market order."
function pong!(
    s::NoMarginStrategy{Sim}, ai, t::Type{<:MarketOrder}; amount, date, kwargs...
)
    o = _create_sim_market_order(s, t, ai; amount, date, kwargs...)
    isnothing(o) && return nothing
    marketorder!(s, o, ai, amount; date, kwargs...)
end

@doc "Cancel orders for a particular asset instance."
function pong!(
    s::Strategy{Sim}, ai::AssetInstance, ::CancelOrders; t::Type{<:OrderSide}=Both
)
    for o in values(orders(s, ai, t))
        cancel!(s, o, ai; err=OrderCancelled(o))
    end
end

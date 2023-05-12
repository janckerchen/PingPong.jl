using Executors: decommit!
function _create_sim_market_order(
    s, t, ai; amount, date, price=priceat(s, t, ai, date), kwargs...
)
    o = marketorder(s, ai, amount; type=t, date, price, kwargs...)
    isnothing(o) && return nothing
    iscommittable(s, o, ai) || return nothing
    commit!(s, o, ai)
    return o
end

@doc "Executes a market order at a particular time if there is volume."
function marketorder!(
    s::Strategy{Sim}, o::Order{<:MarketOrderType}, ai, actual_amount; date, kwargs...
)
    t = trade!(s, o, ai; price=openat(ai, date), date, actual_amount, kwargs...)
    isnothing(t) || begin
        hold!(s, ai, o)
        decommit!(s, o, ai)
    end
    t
end

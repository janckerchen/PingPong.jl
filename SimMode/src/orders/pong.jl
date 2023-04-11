import Executors: pong!
using Executors
using OrderTypes: LimitOrderType, MarketOrderType

@doc "Creates a simulated limit order."
function pong!(
    s::Strategy{Sim}, t::Type{<:Order{<:LimitOrderType}}, ai; amount, kwargs...
)
    o = limitorder(s, ai, amount; type=t, kwargs...)
    isnothing(o) && return nothing
    queue!(s, o, ai)
    limitorder_ifprice!(s, o, o.date, ai)
end

@doc "Progresses a simulated limit order."
function pong!(
    s::Strategy{Sim}, o::Order{<:LimitOrderType}, date::DateTime, ai; kwargs...
)
    limitorder_ifprice!(s, o, date, ai)
end

@doc "Creates a simulated market order."
function pong!(
    s::Strategy{Sim}, t::Type{<:Order{<:MarketOrderType}}, ai; amount, kwargs...
)
    o = marketorder(s, ai, amount; type=t, kwargs...)
    isnothing(o) && return nothing
    queue!(s, o, ai)
    limitorder_ifprice!(s, o, o.date, ai)
end

@doc "Progresses a simulated market order."
function pong!(
    s::Strategy{Sim}, o::Order{<:MarketOrderType}, date::DateTime, ai; kwargs...
)
    limitorder_ifprice!(s, o, date, ai)
end


@doc "Iterates over all pending orders checking for new fills. Should be called only once, precisely at the beginning of a `ping!` function."
function pong!(s::Strategy{Sim}, date, ::UpdateOrders)
    for (ai, ords) in s.sellorders
        for o in ords
            pong!(s, o, date, ai)
        end
    end
    for (ai, ords) in s.buyorders
        for o in ords
            pong!(s, o, date, ai)
        end
    end
end
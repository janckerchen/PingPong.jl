using .Executors: AnyLimitOrder

@doc """ Places a limit order and synchronizes the cash balance.

$(TYPEDSIGNATURES)

This function initiates a limit order through the `_live_limit_order` function. 
Once the order is placed, it synchronizes the cash balance in the live strategy to reflect the transaction. 
It returns the trade information once the transaction is complete.

"""
function pong!(
    s::NoMarginStrategy{Live},
    ai,
    t::Type{<:AnyLimitOrder};
    amount,
    price=lastprice(s, ai, t),
    waitfor=Second(1),
    synced=true,
    kwargs...,
)::Union{<:Trade,Nothing,Missing}
    @timeout_start
    trade = _live_limit_order(s, ai, t; amount, price, waitfor, synced, kwargs)
    if synced && trade isa Trade
        live_sync_cash!(s, ai; since=trade.date, waitfor=@timeout_now)
    end
    trade
end

@doc """ Places a market order and synchronizes the cash balance.

$(TYPEDSIGNATURES)

This function initiates a market order through the `_live_market_order` function. 
Once the order is placed, it synchronizes the cash balance in the live strategy to reflect the transaction. 
It returns the trade information once the transaction is complete.

"""
function pong!(
    s::NoMarginStrategy{Live},
    ai,
    t::Type{<:AnyMarketOrder};
    amount,
    waitfor=Second(5),
    synced=true,
    kwargs...,
)
    @timeout_start
    trade = _live_market_order(s, ai, t; amount, synced, waitfor, kwargs)
    if synced && trade isa Trade
        live_sync_cash!(s, ai; since=trade.date, waitfor=@timeout_now)
    end
    trade
end

@doc """ Cancels all live orders of a certain type and synchronizes the cash balance.

$(TYPEDSIGNATURES)

This function cancels all live orders of a certain side (buy/sell) through the `live_cancel` function. 
Once the orders are cancelled, it waits for confirmation of the cancellation and then synchronizes the cash balance in the live strategy to reflect the cancellations. 
It returns a boolean indicating whether the cancellation was successful.

"""
function pong!(
    s::Strategy{Live},
    ai::AssetInstance,
    ::CancelOrders;
    t::Type{<:OrderSide}=Both,
    waitfor=Second(10),
    confirm=false,
    synced=true,
)
    @timeout_start
    if live_cancel(s, ai; side=t, confirm, all=true)::Bool
        success = waitfor_closed(s, ai, @timeout_now; t)
        if success && synced
            @debug "pong cancel orders: syncing cash" side = orderside(t)
            live_sync_cash!(s, ai; waitfor=@timeout_now)
        end
        @debug "pong cancel orders: " success side = orderside(t)
        success
    else
        @debug "pong cancel orders: failed" side = orderside(t)
        false
    end
end

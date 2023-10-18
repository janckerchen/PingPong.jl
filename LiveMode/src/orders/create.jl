using .Executors: AnyLimitOrder
using .PaperMode: create_sim_limit_order
using .PaperMode.SimMode: construct_order_func
using .Executors.Instruments: AbstractAsset
using .OrderTypes: ordertype
using .Lang: filterkws

function create_live_order(
    s::LiveStrategy,
    resp,
    ai::AssetInstance;
    t,
    price,
    amount,
    synced=true,
    activate=true,
    skipcommit=false,
    kwargs...,
)
    isnothing(resp) && begin
        @warn "create order: empty response ($(raw(ai)))"
        return nothing
    end
    eid = exchangeid(ai)
    side = @something _orderside(resp, eid) orderside(t)
    @debug "Creating order" status = resp_order_status(resp, eid) filled =
        resp_order_filled(resp, eid) > ZERO id = resp_order_id(resp, eid)
    _ccxtisopen(resp, eid) ||
        resp_order_filled(resp, eid) > ZERO ||
        !isempty(resp_order_id(resp, eid)) ||
        begin
            @warn "create order: not open, not partially fillled, id is empty, refusing construction."
            return nothing
        end
    type = let ot = ordertype_fromccxt(resp, eid)
        if isnothing(ot) && t isa Type{<:Order}
            t
        else
            pos = posside(t)
            Order{ot{side},<:AbstractAsset,<:ExchangeID,typeof(pos)}
        end
    end
    amount = resp_order_amount(resp, eid, amount, Val(:amount); ai)
    price = resp_order_price(resp, eid, price, Val(:price); ai)
    loss = resp_order_loss_price(resp, eid)
    profit = resp_order_profit_price(resp, eid)
    date = let this_date = @something pytodate(resp, eid) now()
        # ensure order pricetime doesn't clash
        while haskey(s, ai, (; price, time=this_date), side)
            this_date += Millisecond(1)
        end
        this_date
    end
    id = @something _orderid(resp, eid) begin
        @warn "create order: missing id (default to pricetime hash)" ai = raw(ai) s = nameof(
            s
        )
        string(hash((price, date)))
    end
    o = let f = construct_order_func(type)
        function create()
            f(s, type, ai; id, amount, date, type, price, loss, profit, skipcommit, kwargs...)
        end
        o = create()
        if isnothing(o) && synced
            @warn "create order: can't construct" id = resp_order_id(resp, eid) ai = raw(ai) s = nameof(s)
            @sync begin
                @async live_sync_strategy_cash!(s)
                @async live_sync_universe_cash!(s)
            end
            @debug "create order: locking ai" ai = raw(ai) side = posside(t)
            o = @lock ai create()
        end
        o
    end
    if isnothing(o)
        @error "create order: failed to sync" id ai = raw(ai) s = nameof(s)
        return nothing
    elseif activate
        set_active_order!(s, ai, o; ap=resp_order_average(resp, eid))
    end
    return o
end

function create_live_order(
    s::LiveStrategy,
    ai::AssetInstance,
    args...;
    t,
    amount,
    price=lastprice(s, ai, t),
    exc_kwargs=(),
    kwargs...,
)
    @debug "create order: " ai = raw(ai) t price amount @caller
    resp = live_send_order(
        s, ai, t, args...; amount, price, withoutkws(:date; kwargs=exc_kwargs)...
    )
    create_live_order(s, resp, ai; amount, price, t, kwargs...)
end

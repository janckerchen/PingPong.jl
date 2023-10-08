using .Executors.Instruments: freecash

const TriggerOrderTuple = NamedTuple{(:type, :price, :trigger)}

function trigger_dict(exc, v)
    out = pydict()
    out[@pyconst("type")] = _ccxtordertype(exc, v.type)
    out[@pyconst("price")] = pyconvert(Py, v.price)
    out[@pyconst("triggerPrice")] = pyconvert(Py, v.trigger)
    out
end

function check_available_cash(s, _, amount, price, ::Type{<:IncreaseOrder})
    abs(freecash(s)) >= abs(amount) * price
end

function check_available_cash(_, ai, amount, _, o::Type{<:ReduceOrder})
    abs(freecash(ai, posside(o))) >= abs(amount)
end

function live_send_order(
    s::LiveStrategy,
    ai,
    t=GTCOrder{Buy},
    args...;
    amount,
    price=lastprice(s, ai, t),
    retries=0,
    post_only=false,
    reduce_only=false,
    stop_trigger=nothing,
    profit_trigger=nothing,
    stop_loss::Option{TriggerOrderTuple}=nothing,
    take_profit::Option{TriggerOrderTuple}=nothing,
    skipchecks=false,
    kwargs...,
)
    skipchecks ||
        check_available_cash(s, ai, amount, price, t) ||
        begin
            @warn "send order: not enough cash. out of sync?" this_cash = cash(
                ai, posside(t)
            ) ai_comm = committed(ai, posside(t)) ai_free = freecash(ai, posside(t)) strat_cash = cash(
                s
            ) strat_comm = committed(s) order_cash = amount t
            return nothing
        end
    sym = raw(ai)
    exc = exchange(ai)
    side = _ccxtorderside(t)
    type = _ccxtordertype(exc, t)
    tif = _ccxttif(exc, t)
    tif_k = @pystr(time_in_force_key(exc))
    tif_v = @pystr(time_in_force_value(exc, asset(ai), tif))
    params = LittleDict{Py,Any}(@pystr(k) => pyconvert(Py, v) for (k, v) in kwargs)
    get!(params, tif_k, tif_v)
    function supportmsg(feat)
        @warn "send order: not supported" feat exc = nameof(exc)
    end
    get!(params, @pyconst("postOnly"), post_only) &&
        (has(exc, :createPostOnlyOrder) || supportmsg("Post Only"))
    get!(params, @pyconst("reduceOnly"), reduce_only) &&
        (has(exc, :createReduceOnlyOrder) || supportmsg("Reduce Only"))
    isnothing(stop_loss) || let stop_k = @pyconst("stopLoss")
        haskey(params, stop_k) || (params[stop_k] = trigger_dict(exc, stop_loss))
    end
    isnothing(take_profit) || let take_k = @pyconst("takeProfit")
        haskey(params, take_k) || (params[take_k] = trigger_dict(exc, take_profit))
    end
    isnothing(stop_trigger) || let stop_k = @pyconst("stopLossPrice")
        haskey(params, stop_k) || (params[stop_k] = pyconvert(Py, stop_trigger))
    end
    isnothing(profit_trigger) || let take_k = @pyconst("takeProfitPrice")
        haskey(params, take_k) || (params[take_k] = pyconvert(Py, profit_trigger))
    end
    # start monitoring before sending the create request
    watch_trades!(s, ai)
    watch_orders!(s, ai)
    resp = create_order(s, sym, args...; side, type, price, amount, params)
    while resp isa Exception && retries > 0
        retries -= 1
        resp = create_order(s, sym, args...; side, type, price, amount, params)
    end
    if resp isa PyException
        @warn "send order: exception" sym ex = nameof(exchange(ai)) resp args params
        return nothing
    end
    resp isa Exception || (pyisnone(resp_order_id(resp, exchangeid(ai))) && return nothing)
    resp
end

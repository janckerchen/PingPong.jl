import .SimMode: maketrade, trade!
using .SimMode: @maketrade, iscashenough, cost
using .Misc.TimeToLive: safettl

@doc """ Checks and filters trades based on a timestamp.

$(TYPEDSIGNATURES)

The function checks if the response is a list. If not, it issues a warning and returns `nothing`.
If a `since` timestamp is provided, it filters out trades that occurred before this timestamp.
The function returns the filtered list of trades or the original response if no `since` timestamp is provided.

"""
function _check_and_filter(resp; ai, since, kind="")
    pyisinstance(resp, pybuiltins.list) || begin
        @warn "Couldn't fetch $kind trades for $(raw(ai))"
        return nothing
    end
    if isnothing(since)
        resp
    else
        out = pylist()
        for t in resp
            _timestamp(t, exchangeid(ai)) >= since && out.append(t)
        end
        out
    end
end

function _timestamp(v, eid::EIDType)
    pyconvert(Int, resp_trade_timestamp(v, eid)) |> TimeTicks.dtstamp
end

@doc """ Fetches and filters the user's trades.

$(TYPEDSIGNATURES)

The function fetches the user's trades using the `fetch_my_trades` function.
If a `since` timestamp is provided, it filters out trades that occurred before this timestamp using the `_check_and_filter` function.
The function returns the filtered list of trades or the original response if no `since` timestamp is provided.

"""
function live_my_trades(s::LiveStrategy, ai; since=nothing, kwargs...)
    resp = fetch_my_trades(s, ai; since, kwargs...)
    _check_and_filter(resp; ai, since)
end

@doc """ Fetches and filters trades for a specific order

$(TYPEDSIGNATURES)

This function fetches the trades associated with a specific order using the `fetch_order_trades` function.
If a `since` timestamp is provided, it filters out trades that occurred before this timestamp using the `_check_and_filter` function.
The function returns the filtered list of trades or the original response if no `since` timestamp is provided.

"""
function live_order_trades(s::LiveStrategy, ai, id; since=nothing, kwargs...)
    resp = fetch_order_trades(s, ai, id; since, kwargs...)
    _check_and_filter(resp; ai, since, kind="order")
end

@doc "A named tuple representing the ccxt fields of a trade."
const Trf = NamedTuple(
    Symbol(f) => f for f in (
        "id",
        "timestamp",
        "datetime",
        "symbol",
        "order",
        "type",
        "side",
        "takerOrMaker",
        "price",
        "amount",
        "cost",
        "fee",
        "fees",
        "currency",
        "rate",
    )
)

function check_limits(v, ai, lim_sym)
    lims = ai.limits
    min = getproperty(lims, lim_sym).min
    max = getproperty(lims, lim_sym).max

    min <= v <= max || begin
        @warn "Trade amount $(v) outside limits ($(min)-$(max))"
        return false
    end
end

@doc "A cache for storing market symbols by currency with a time-to-live of 360 seconds."
const MARKETS_BY_CUR = safettl(Tuple{ExchangeID,String}, Vector{String}, Second(360))
function anyprice(cur::String, sym, exc)
    try
        v = lastprice(sym, exc)
        v <= zero(v) || return v
        for sym in @lget! MARKETS_BY_CUR (exchangeid(exc), cur) [
            k for k in Iterators.reverse(collect(keys(exc.markets))) if startswith(k, cur)
        ]
            v = lastprice(sym, exc)
            v <= zero(v) || return v
        end
        return ZERO
    catch
        return ZERO
    end
end

_feebysign(rate, cost) = rate >= ZERO ? cost : -cost
@doc """ Calculates the fee from a fee dictionary

$(TYPEDSIGNATURES)

This function calculates the fee from a fee dictionary. 
It retrieves the rate and cost from the fee dictionary and then uses the `_feebysign` function to calculate the fee based on the rate and cost.

"""
function _getfee(fee_dict, cost=get_float(fee_dict, "cost"))
    rate = get_float(fee_dict, "rate")
    _feebysign(rate, cost)
end

@doc """ Determines the fee cost based on the currency

$(TYPEDSIGNATURES)

This function determines the fee cost based on the currency specified in the fee dictionary. 
If the currency matches the quote currency, it returns the fee in quote currency. 
If the currency matches the base currency, it returns the fee in base currency. 
If the currency doesn't match either, it returns zero for both.

"""
function _feecost(
    fee_dict, ai, ::EIDType=exchangeid(ai); qc_py=@pystr(qc(ai)), bc_py=@pystr(qc(ai))
)
    cur = get_py(fee_dict, "currency")
    if pyeq(Bool, cur, qc_py)
        (_getfee(fee_dict), ZERO)
    elseif pyeq(Bool, cur, bc_py)
        (ZERO, _getfee(fee_dict))
    else
        (ZERO, ZERO)
    end
end

# This tries to always convert the fees in quote currency
# function _feecost_quote(s, ai, bc_price, date, qc_py=@pystr(qc(ai)), bc_py=@pystr(bc(ai)))
#     if pyeq(Bool, cur, bc_py)
#         _feebysign(rate, cost * bc_price)
#     else
#         # Fee currency is neither quote nor base, fetch the price from the candle
#         # of the related spot pair with the trade quote currency at the trade date
#         try
#             spot_pair = "$cur/$qc_py"
#             price = @something priceat(s, ai, date; sym=spot_pair, step=:close) anyprice(
#                 string(cur), spot_pair, exchange(ai)
#             )
#             _feebysign(rate, cost * price)
#         catch
#         end
#     end
# end

@doc """ Determines the currency of the fee based on the order side

$(TYPEDSIGNATURES)

This function determines the currency of the fee based on the side of the order. 
It uses the `feeSide` property of the market associated with the order. 
The function returns `:base` if the fee is in the base currency and `:quote` if the fee is in the quote currency.

"""
function trade_feecur(ai, side::Type{<:OrderSide})
    # Default to get since it should be the most common
    feeside = get(market(ai), "feeSide", "get")
    if feeside == "get"
        if side == Buy
            :base
        else
            :quote
        end
    elseif feeside == "give"
        if side == Sell
            :base
        else
            :quote
        end
    elseif feeside == "quote"
        :quote
    elseif feeside == "base"
        :base
    else
        :quote
    end
end

@doc """ Calculates the default trade fees based on the order side

$(TYPEDSIGNATURES)

This function calculates the default trade fees based on the side of the order and the current market conditions. 
It uses the `trade_feecur` function to determine the currency of the fee and then calculates the fee based on the amount and cost of the trade.

"""
function _default_trade_fees(
    ai, side::Type{<:OrderSide}; fees_base, fees_quote, actual_amount, net_cost
)
    feecur = trade_feecur(ai, side)
    default_fees = maxfees(ai)
    if feecur == :base
        fees_base += actual_amount * default_fees
    else
        fees_quote += net_cost * default_fees
    end
    (fees_quote, fees_base)
end

market(ai) = exchange(ai).markets[raw(ai)]
@doc """ Determines the trade fees based on the response and side of the order

$(TYPEDSIGNATURES)

This function determines the trade fees based on the response from the exchange and the side of the order. 
It first checks if the response contains a fee dictionary. If it does, it calculates the fee cost based on the dictionary. 
If the response does not contain a fee dictionary but contains a list of fees, it calculates the total fee cost from the list. 
If the response does not contain either, it calculates the default trade fees.

"""
function _tradefees(resp, side, ai; actual_amount, net_cost)
    eid = exchangeid(ai)
    v = resp_trade_fee(resp, eid)
    if pyisinstance(v, pybuiltins.dict)
        return _feecost(v, ai, eid)
    end
    v = resp_trade_fees(resp, eid)
    fees_quote, fees_base = ZERO, ZERO
    if pyisinstance(v, pybuiltins.list) && !isempty(v)
        qc_py = @pystr(qc(ai))
        bc_py = @pystr(bc(ai))
        for fee in v
            (q, b) = _feecost(fee, ai, eid; qc_py, bc_py)
            fees_quote += q
            fees_base += b
        end
    end
    if iszero(fees_quote) && iszero(fees_base)
        (fees_quote, fees_base) = _default_trade_fees(
            ai, side; fees_base, fees_quote, actual_amount, net_cost
        )
    end
    return (fees_quote, fees_base)
end

_addfees(net_cost, fees_quote, ::IncreaseOrder) = net_cost + fees_quote
_addfees(net_cost, fees_quote, ::ReduceOrder) = net_cost - fees_quote

@doc """ Checks if the trade symbol matches the order symbol

$(TYPEDSIGNATURES)

This function checks if the trade symbol from the response matches the symbol of the order. 
If they do not match, it issues a warning and returns `false`.

"""
function check_symbol(ai, o, resp, eid::EIDType; getter=resp_trade_symbol)::Bool
    pyeq(Bool, getter(resp, eid), @pystr(raw(ai))) || begin
        @warn "Mismatching trade for $(raw(ai))($(resp_trade_symbol(resp, eid))), order: $(o.asset), refusing construction."
        return false
    end
end

@doc """ Checks if the response is of the expected type

$(TYPEDSIGNATURES)

This function checks if the response from the exchange is of the expected type. 
If the response is not of the expected type, it issues a warning and returns `false`.

"""
function check_type(ai, o, resp, ::EIDType; type=pybuiltins.dict)::Bool
    pyisinstance(resp, type) || begin
        @warn "Invalid response for order $(raw(ai)), order: $o, refusing construction."
        return false
    end
end

@doc """ Checks if the trade id matches the order id

$(TYPEDSIGNATURES)

This function checks if the trade id from the response matches the id of the order. 
If they do not match, it issues a warning and returns `false`.

"""
function check_id(ai, o, resp, eid::EIDType; getter=resp_trade_order)::Bool
    string(getter(resp, eid)) == o.id || begin
        @warn "Mismatching id $(raw(ai))($(resp_trade_order(resp, eid))), order: $(o.id), refusing construction."
        return false
    end
end

@doc """ Checks if the trade side matches the order side

$(TYPEDSIGNATURES)

This function checks if the side of the trade from the response matches the side of the order. 
If they do not match, it issues a warning and returns `false`.

"""
function _check_side(side, o)::Bool
    side == orderside(o) || begin
        @warn "Mismatching trade side $side and order side $(orderside(o)), refusing construction."
        return false
    end
end

@doc """ Checks if the trade price is valid

$(TYPEDSIGNATURES)

This function checks if the trade price from the response is approximately equal to the order price or if the order is a market order. 
If the price is far off from the order price, it issues a warning. 
The function also checks if the price is greater than zero, issuing a warning and returning `false` if it's not.

"""
function _check_price(s, ai, actual_price, o; resp)::Bool
    isapprox(actual_price, o.price; rtol=0.05) ||
        o isa AnyMarketOrder ||
        begin
            @warn "Trade price far off from order price, order: $(o.price), exchange: $(actual_price) ($(nameof(s)) @ ($(raw(ai)))"
        end
    actual_price > ZERO || begin
        @warn "Trade price can't be zero, ($(nameof(s)) @ ($(raw(ai))) tradeid: ($(resp_trade_id(resp, exchangeid(ai))), refusing construction."
        return false
    end
end

@doc """ Checks if the trade amount is valid

$(TYPEDSIGNATURES)

This function checks if the trade amount from the response is greater than zero. 
If it's not, it issues a warning and returns `false`.

"""
function _check_amount(s, ai, actual_amount; resp)::Bool
    actual_amount > ZERO || begin
        @warn "Trade amount can't be zero, ($(nameof(s)) @ ($(raw(ai))) tradeid: ($(resp_trade_id(resp, exchangeid(ai))), refusing construction."
        return false
    end
end

@doc """ Warns if the local cash is not enough for the trade

$(TYPEDSIGNATURES)

This function checks if the local cash is enough for the trade. 
If it's not, it issues a warning.

"""
function _warn_cash(s, ai, o; actual_amount)
    iscashenough(s, ai, actual_amount, o) ||
        @warn "make trade: local cash not enough" cash(ai) o.id actual_amount
end

@doc """ Constructs a trade based on the order and response

$(TYPEDSIGNATURES)

This function constructs a trade based on the order and the response from the exchange. 
It performs several checks on the response, such as checking the type, symbol, id, side, price, and amount. 
If any of these checks fail, the function returns `nothing`. 
Otherwise, it calculates the fees, warns if the local cash is not enough for the trade, and constructs the trade.

"""
function maketrade(s::LiveStrategy, o, ai; resp, trade::Option{Trade}=nothing, kwargs...)
    eid = exchangeid(ai)
    trade isa Trade && return trade
    check_type(ai, o, resp, eid) || return nothing
    check_symbol(ai, o, resp, eid) || return nothing
    check_id(ai, o, resp, eid) || return nothing
    side = _ccxt_sidetype(resp, eid; o)
    _check_side(side, o) || return nothing
    actual_amount = resp_trade_amount(resp, eid)
    actual_price = resp_trade_price(resp, eid)
    _check_price(s, ai, actual_price, o; resp) || return nothing
    check_limits(actual_price, ai, :price)
    if actual_amount <= ZERO
        @debug "Amount value absent from trade or wrong ($actual_amount)), using cost."
        net_cost = resp_trade_cost(resp, eid)
        actual_amount = net_cost / actual_price
        _check_amount(s, ai, actual_amount; resp) || return nothing
    else
        net_cost = cost(actual_price, actual_amount)
    end
    check_limits(net_cost, ai, :cost)
    check_limits(actual_amount, ai, :amount)

    _warn_cash(s, ai, o; actual_amount)
    date = @something pytodate(resp, eid) now()

    fees_quote, fees_base = _tradefees(resp, side, ai; actual_amount, net_cost)
    size = _addfees(net_cost, fees_quote, o)

    @debug "Constructing trade" cash = cash(ai, posside(o)) ai = raw(ai) s = nameof(s)
    @maketrade
end


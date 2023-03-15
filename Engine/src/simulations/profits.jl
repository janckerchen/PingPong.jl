@doc "When the candle is _red_, `high` happens before `low`."
ishighfirst(open, close) = close <= open

@doc "Calc the profits given the open and close price, with amounts and fees.

- The `*_price` is the _quote_ price, usually within OHLC boundaries.
"
function profitat(open_price::Real, close_price, fee; digits=8)
    shares = 1. / open_price
    # How much the trade is worth at open
    open_value = shares * open_price
    # How much the trade is worth at close
    close_value = shares * close_price
    # How much was spent opening the trade with fees
    value_spent = open_value + open_value * fee
    # How much was returned, minus fees
    value_returned = close_value - close_value * fee
    profits = value_returned / value_spent - 1.0
    round(profits; digits)
end

slippage(args...) = 0.0

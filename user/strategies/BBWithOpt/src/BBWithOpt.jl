module BBWithOpt

using PingPong
@strategyenv!
@contractsenv!
@optenv!
using Indicators
# @contractsenv!
# @optenv!

const NAME = :BBWithOpt
# const EXCID = ExchangeID(:phemex)
# const S{M} = Strategy{M,NAME,typeof(EXCID),NoMargin}
const SC{E,M,R} = Strategy{M,NAME,E,R}
const TF = tf"1m"
__revise_mode__ = :eval

function bbands!(ohlcv, from_date; n=20, sigma=2.0)
    bb = bbands(ohlcv.close; n, sigma)
    @assert bb[end, 1] <= bb[end, 2] <= bb[end, 3]
    # shift by one to avoid lookahead # FIXME: this should not be needed
    [shift!(bb[:, 1], 1) shift!(bb[:, 3], 1)]
end

function ping!(s::SC{<:ExchangeID,Sim}, ::ResetStrategy)
    attrs = s.attrs
    n = get(attrs, :param_n, 20)
    sigma = get(attrs, :param_sigma, 2.0)
    pong!(
        (args...) -> bbands!(args...; n, sigma), s, InitData(); cols=(:bb_lower, :bb_upper)
    )
end

ping!(_::SC, ::WarmupPeriod) = Day(1)

function handler(s, ai, ats, ts)
    """
    1) Compute indicators from data
    """
    pong!(bbands!, s, ai, UpdateData(); cols=(:bb_lower, :bb_upper))
    ohlcv = ai.data[s.timeframe]

    lower = ohlcv[ats, :bb_lower]
    upper = ohlcv[ats, :bb_upper]
    current_price = closeat(ohlcv, ats)

    """
    2) Fetch portfolio
    """
    # disposable balance not committed to any pending order
    balance_quoted = s.self.freecash(s)
    # we invest only 80% of available liquidity
    buy_value = float(balance_quoted) * 0.80

    """
    3) Fetch position for symbol
    """
    has_position = isopen(ai, Long())
    prev_trades = length(trades(ai))

    """
    4) Resolve buy or sell signals
    """
    if current_price < lower && !has_position
        @linfo "buy signal: creating market order" sym = raw(ai) buy_value current_price
        amount = buy_value / current_price
        pong!(s, ai, MarketOrder{Buy}; date=ts, amount)
    elseif current_price > upper && has_position
        @linfo "sell signal: closing position" exposure = value(ai) current_price
        pong!(s, ai, Long(), ts, PositionClose())
    end
    """
    5) Check strategy profitability
    """
    if length(trades(ai)) > prev_trades
        # ....
    end
end

function ping!(s::T, ts::DateTime, _) where {T<:SC}
    ats = available(s.timeframe, ts)
    foreach(s.universe) do ai
        handler(s, ai, ats, ts)
    end
end

function ping!(t::Type{<:SC}, config, ::LoadStrategy)
    assets = marketsid(t)
    sandbox = config.mode == Paper() ? false : config.sandbox
    timeframe = tf"1h"
    s = Strategy(@__MODULE__, assets; config, sandbox, timeframe)
    @assert marginmode(s) == config.margin
    @assert execmode(s) == config.mode
    s[:verbose] = false

    if issim(s)
        ##  whatever method to load the data, e.g.
        # pair = first(marketsid(s))
        # quote_currency = string(nameof(s.cash))
        # data = Scrapers.BinanceData.binanceload(pair; quote_currency)
        # Engine.stub!(s.universe, data)
        # NOTE: `Scrapers` is not imported by default, if you want to use it here you
        # have to add it manually to the strategy.
        # Recommended to just stub the data with a function defined in the REPL
    else
        pong!(s, WatchOHLCV())
    end
    s
end

function marketsid(::Type{<:SC})
    String["BTC/USDT:USDT"]
end

## Optimization
THREADSAFE = Ref(false)
function ping!(s::SC, ::OptSetup)
    (;
        ctx=Context(Sim(), tf"1h", dt"2020-", now()),
        params=(n=1:120, sigma=1.5:0.1:2.5),
        space=(kind=:MixedPrecisionRectSearchSpace, precision=Int[1, 1]),
    )
end
function ping!(s::SC, params, ::OptRun)
    attrs = s.attrs
    attrs[:params_n] = params[1]
    attrs[:params_sigma] = params[2]
end

function ping!(s::SC, ::OptScore)::Vector
    [stats.sharpe(s)]
end

end

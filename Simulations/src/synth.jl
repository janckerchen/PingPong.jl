using Data: ohlcvtuple, to_ohlcv
using Processing: resample
using Random: rand
using Base: DEFAULT_STABLE
using Misc: config
using Lang: @deassert
import Data: stub!

const DEFAULT_DATE = dt"2020-01-01"

function synthcandle(
    ts::DateTime,
    seed_price::Real,
    seed_vol::Real;
    u_price::Real,
    u_vol::Real,
    bound_price::Real,
    bound_vol::Real,
)
    open = let step = rand((-bound_price):u_price:bound_price)
        m = seed_price + step
        m <= 0.0 ? seed_price : m
    end
    high = let step = rand(0:u_price:bound_price)
        open + step
    end
    low = let step = rand(0:u_price:bound_price)
        open - step
    end
    close = let step = rand((-bound_price):u_price:bound_price)
        max(u_price, open + step * (high - low))
    end
    volume = let step = rand((-bound_vol):u_vol:bound_vol)
        m = seed_vol * (low / high) + step
        m <= 0.0 ? abs(step) : m
    end
    (ts, open, high, low, close, volume)
end

function synthohlcv(
    len=1000;
    tf=tf"1m",
    seed_price=100.0,
    seed_vol=seed_price * 10.0,
    vt_price=3.0,
    vt_vol=3.0,
    u_price=seed_price * 0.01,
    u_vol=seed_vol * 0.5,
    start_date=DEFAULT_DATE,
)
    ans = ohlcvtuple()
    bound_price = u_price * vt_price
    bound_vol = u_vol * vt_vol
    c = synthcandle(
        start_date, seed_price, seed_vol; u_price, u_vol, bound_price, bound_vol
    )
    push!(ans, c)
    ts = start_date + tf
    open = c[5]
    vol = c[6]
    for _ in 1:len
        c = synthcandle(ts, open, vol; u_price, u_vol, bound_price, bound_vol)
        push!(ans, c)
        open = c[5]
        vol = c[6]
        ts += tf
    end
    ans
end

_setorappend(d::AbstractDict, k, v) = begin
    prev = get(d, k, nothing)
    if isnothing(prev)
        d[k] = v
    else
        append!(prev, v)
    end
end

@doc "Fills an asset instance with syntethic ohlcv data."
function stub!(
    ai::AssetInstance,
    len=1000,
    tfs::Vector{TimeFrame}=collect(keys(ai.data));
    seed_price=100.0,
    seed_vol=1000.0,
    vt_price=3.0,
    vt_vol=500.0,
    start_date=DEFAULT_DATE,
)
    isempty(tfs) && (tfs = config.timeframes)
    sort!(tfs)
    empty!(ai.data)
    min_tf = first(tfs)
    ohlcv =
        synthohlcv(len; tf=min_tf, vt_price, vt_vol, seed_price, seed_vol, start_date) |>
        to_ohlcv
    _setorappend(ai.data, min_tf, ohlcv)
    if length(tfs) > 1
        for t in tfs[2:end]
            _setorappend(ai.data, t, resample(ohlcv, min_tf, t))
        end
    end
end
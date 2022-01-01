import Base.filter

@doc "Filters a list of pairs using a predicate function. The predicate functions must return a `Real` number which will be used for sorting."
function filter(pred::Function, pairs::AbstractDict, min_v::Real, max_v::Real)
    flt = PairData[]
    idx = Real[]
    for (name, p) in pairs
        v = pred(p.data)
        if max_v > v > min_v
            push!(idx, searchsortedfirst(idx, v))
            push!(flt, p)
        end
    end
    flt[idx]
end

function slopefilter(timeframe="1d"; qc="USDT", minv=10., maxv=90., window=20)
    exc[] == pynone && throw("Global exchange variable is not set.")
    pairs = get_pairlist(exc[], qc)
    pairs = load_pairs(zi, exc[], pairs, timeframe)
    pred = x -> slopeangle(x; window)
    filter(pred, pairs, minv, maxv)
end

function slopefilter(pairs::AbstractVector; minv=10., maxv=90., window=20)
    pred = x -> slopeangle(x; window)
    filter(pred, pairs, minv, maxv)
end


using DataStructures: CircularDeque
@doc "Resamples ohlcv data from a smaller to a higher timeframe."
function resample(pair::PairData, timeframe; save=true)
    @debug @assert all(cleanup_ohlcv_data(data, pair.tf).timestamp .== pair.data.timestamp) "Resampling assumptions are not met, expecting cleaned data."

    @as_td
    src_prd = data_td(pair.data)
    src_td = timefloat(src_prd)

    @assert td > src_td "Upsampling not supported."
    td === src_td && return pair
    frame_size::Integer = td ÷ src_td

    data = pair.data

    # remove incomplete candles at timeseries edges, a full resample requires candles with range 1:frame_size
    left = 1
    while (data.timestamp[left] |> timefloat) % td !== 0.
        left += 1
    end
    right = size(data, 1)
    let last_sample_candle_remainder = src_td * (frame_size - 1)
        while (data.timestamp[right] |> timefloat) % td !== last_sample_candle_remainder
            right -= 1
        end
    end
    data = @view data[left:right, :]

    data[!, :sample] = timefloat.(data.timestamp) .÷ td
    gb = groupby(pair.data, :sample)
    df = combine(gb, :timestamp => first, :open => first, :high => maximum, :low => minimum, :close => last, :volume => sum; renamecols=false)
    select!(pair.data, Not(:sample))
    return select!(df, Not(:sample))
end

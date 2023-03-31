using Lang
using Data.DFUtils
using Data.DataFramesMeta
using Data
using Stats.Statistics: median

zeromissing!(v) = begin
    for i in eachindex(v)
        ismissing(v[i]) && (v[i] = 0.0)
    end
    v
end

possum(x, y) = begin
    max(0.0, x + y)
end
orzero(; atol=1e-15) = v -> orzero(v, atol)
orzero(v, atol=1e-15) = isapprox(v, 0.0; atol) ? 0.0 : v
appsum(x, y, atol=1e-15) = orzero(x + y, atol)

aroundtrades(ai, tf) = begin
    start_date = first(ai.history).order.date - tf
    stop_date = last(ai.history).date + tf
    df = ai.ohlcv[DateRange(start_date, stop_date)]
    df = resample(df, tf)
end

@doc """Plots the trade history of a single asset instance.

!!! warning "For single assets only"
    If your strategy trades multiple assets the profits returned by this function
    won't match the strategy actual holdings since calculation are done only w.r.t
    this single asset.
"""
function trades_balance(
    ai::AssetInstance; tf=tf"1d", return_all=true, df=aroundtrades(ai, tf), initial_cash=0.0
)
    isempty(ai.history) && return nothing
    trades = resample_trades(ai, tf; style=:minimal)
    df = outerjoin(df, trades; on=:timestamp, order=:left)
    transform!(
        df,
        :quote_balance => zeromissing!,
        :base_balance => zeromissing!,
        :quote_balance => (x -> accumulate(+, x; init=initial_cash)) => :cum_quote,
        :base_balance => (x -> accumulate(orzero() ∘ +, x; init=0.0)) => :cum_base;
        renamecols=false,
    )
    if return_all
        df[!, :cum_value_balance] = df.cum_base .* df.close
        df[!, :cum_total] = df.cum_quote + df.cum_value_balance
        df
    else
        df.cum_quote + df.cum_base .* df.close
    end
end

function trades_balance(s::Strategy, aa; kwargs...)
    trades_balance(s.universe[aa].instance; kwargs...)
end

function trades_balance(
    s::Strategy, tf::TimeFrame=tf"1d", args...; return_all=true, kwargs...
)
    df = resample_trades(s, tf; style=:minimal)
    isnothing(df) && return nothing
    # Expand dates
    df = outerjoin(DataFrame(:timestamp => collect(daterange(df, tf))), df; on=:timestamp)
    # We need to accumulate base balances for each asset
    let dict_type = Dict{AssetInstance,eltype(df.quote_balance)},
        value_dict = dict_type(ai => 0.0 for ai in s.universe),
        cum_base_dict = dict_type(ai => 0.0 for ai in s.universe)

        @eachrow! df begin
            @newcol :cum_value_balance::typeof(df.quote_balance)
            ai = :instance
            # only update values if there are trades for this timestamp
            ismissing(ai) || begin
                # we only accumulate the *amounts* of the assets
                cum_base_dict[ai] += :base_balance
                # while the actual cash value is updated in place.
                value_dict[ai] = cum_base_dict[ai] * closeat(ai, :timestamp)
            end
            # on each timestamp, update the known total value of the assets.
            # The sum of all assets value will be correct only on the last
            # trade for a particular timestamp.
            :cum_value_balance = sum(values(value_dict))
        end
    end
    # Now we can sum all assets over their quote balance.
    # The value balance is already in cumulative form,
    # therefore we only take the last value, which ensures that all assets balances are updated
    # since grouping does not affect the order (see line :81)
    gb = groupby(df, :timestamp)
    df = combine(
        gb,
        :quote_balance => sum ∘ skipmissing,
        :cum_value_balance => last,
        ;
        renamecols=false,
    )
    # Add initial cash before cumsum
    df.quote_balance[begin] += s.initial_cash
    transform!(df, :quote_balance => cumsum ∘ skipmissing => :cum_quote)
    # finally the total at each timestamp is given by the cumulative quote balance
    # summed to the value of all the assets at each timestamp.
    df[!, :cum_total] = df.cum_quote + df.cum_value_balance
    if return_all
        df
    else
        df.cum_total
    end
end

ffill!(v, out=v) = begin
    f = first(v)
    @assert !ismissing(f)
    accumulate!(((x, y) -> coalesce(y, x)), out, v; init=f)
end
ffill(v) = ffill!(v, similar(v))

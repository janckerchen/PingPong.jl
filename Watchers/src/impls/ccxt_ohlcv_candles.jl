const PRICE_SOURCES = (:last, :vwap, :bid, :ask)
const CcxtOHLCVCandlesVal = Val{:ccxt_ohlcv_candles}

baremodule LogOHLCVWatcher end

function ccxt_ohlcv_candles_watcher(
    exc::Exchange,
    syms;
    timeframe=tf"1m",
    logfile=nothing,
    buffer_capacity=100,
    view_capacity=count(timeframe, tf"1d") + 1 + buffer_capacity,
    default_view=nothing,
    n_jobs=ratelimit_njobs(exc),
    callback=nothing,
    kwargs...,
)
    a = Dict{Symbol,Any}()
    a[k"ids"] = [string(v) for v in syms]
    a[k"issandbox"] = issandbox(exc)
    @setkey! a exc
    @setkey! a default_view
    @setkey! a timeframe
    @setkey! a n_jobs
    @setkey! a callback
    a[k"minrows_warned"] = false
    a[k"sem"] = Base.Semaphore(n_jobs)
    a[k"key"] = string(
        "ccxt_", exc.name, issandbox(exc), "_ohlcv_candles_", join(a[k"ids"], "_")
    )
    if !isnothing(logfile)
        @setkey! a logfile
    end
    watcher_type = Py
    wid = string(
        CcxtOHLCVCandlesVal.parameters[1], "-", hash((exc.id, syms, a[k"issandbox"]))
    )
    w = watcher(
        watcher_type,
        wid,
        CcxtOHLCVCandlesVal();
        start=false,
        load=false,
        flush=false,
        process=false,
        buffer_capacity,
        view_capacity,
        fetch_interval=Second(1),
        attrs=a,
    )
    w
end

_fetch!(w::Watcher, ::CcxtOHLCVCandlesVal; sym=nothing) = _tfunc(w)()

function _init!(w::Watcher, ::CcxtOHLCVCandlesVal)
    _view!(w, default_view(w, Dict{String,DataFrame}))
    a = attrs(w)
    a[k"loaded"] = Dict{String,Bool}()
    a[k"sym_locks"] = Dict{String,ReentrantLock}()
    a[k"fetch_backoff"] = Dict{String,Int}()
    _initsyms!(w)
    _checkson!(w)
end

_process!(::Watcher, ::CcxtOHLCVCandlesVal) = nothing

function _start!(w::Watcher, ::CcxtOHLCVCandlesVal)
    _reset_candles_func!(w)
    a = w.attrs
    a[k"sem"] = Base.Semaphore(a[k"n_jobs"])
end

_stop!(w::Watcher, ::CcxtOHLCVCandlesVal) = begin
    if haskey(w.attrs, :handlers)
        for sym in _ids(w)
            stop_handler_task!(w, sym)
        end
    elseif haskey(w.attrs, :handler)
        stop_handler_task!(w)
    end
end

@doc """ Loads the OHLCV data for a specific symbol.

$(TYPEDSIGNATURES)

This function loads the OHLCV data for a specific symbol.
If the symbol is not being tracked by the watcher or if the data for the symbol has already been loaded, the function returns nothing.

"""
_load!(w::Watcher, ::CcxtOHLCVCandlesVal, sym) = _load_ohlcv!(w, sym)

@doc """ Loads the OHLCV data for all symbols.

$(TYPEDSIGNATURES)

This function loads the OHLCV data for all symbols.
If the buffer or view of the watcher is empty, the function returns nothing.

"""
_loadall!(w::Watcher, ::CcxtOHLCVCandlesVal) = _load_all_ohlcv!(w)

function _reset_candles_func!(w)
    attrs = w.attrs
    eid = exchangeid(_exc(w))
    exc = getexchange!(eid; sandbox=attrs[k"issandbox"])
    _exc!(attrs, exc)
    # don't pass empty args to imply all symbols
    ids = _check_ids(exc, _ids(w))
    @assert ids isa Vector && !isempty(ids) "ohlcv (candles)  no symbols to watch given"
    tf = _tfr(w)
    tf_str = string(tf)
    init_tasks = @lget! attrs k"process_tasks" Set{Task}()
    init_func() =
        for sym in ids
            push!(init_tasks, @async begin
                @lock _symlock(w, sym) _ensure_ohlcv!(w, sym)
                delete!(init_tasks, current_task())
            end)
        end
    if has(exc, :watchOHLCVForSymbols)
        watch_func = exc.watchOHLCVForSymbols
        wrapper_func = _update_ohlcv_func(w)
        syms = [@py([sym, tf_str]) for sym in ids]
        corogen_func = (_) -> coro_func() = watch_func(syms)
        handler_task!(w; init_func, corogen_func, wrapper_func, if_func=!isempty)
        _tfunc!(attrs, () -> check_task!(w))
    elseif has(exc, :watchOHLCV)
        w[:handlers] = Dict{String,WatcherHandler1}()
        watch_func = exc.watchOHLCV
        syms = [(sym, tf) for sym in ids]
        for sym in ids
            wrapper_func = _update_ohlcv_func_single(w, sym)
            corogen_func = (_) -> coro_func() = watch_func(sym; timeframe=tf_str)
            handler_task!(w, sym; init_func, corogen_func, wrapper_func, if_func=!isempty)
        end
        check_all_handlers() = all(check_task!(w, sym) for sym in ids)
        _tfunc!(attrs, check_all_handlers)
    else
        error(
            "ohlcv (candles) watcher only works with exchanges that support `watchOHLCVforSymbols` functions",
        )
    end
end

function _update_ohlcv_func(w)
    view = _view(w)
    tf = _tfr(w)
    tf_str = _tfr(w) |> string
    function ohlcv_wrapper_func(snap)
        if snap isa Exception
            @error "ohlcv (candles): exception" exception = snap
            return nothing
        elseif !isdict(snap)
            @error "ohlcv (candles): unknown value" snap
            return nothing
        end
        latest_ts = apply(tf, now())
        for (sym, tf_candles) in snap
            this_df = view[sym]
            if isempty(this_df)
                @debug "ohlcv (candles): waiting for startup fetch" _module =
                    LogOHLCVWatcher sym
                continue
            end
            next_ts = _nextdate(this_df, tf)
            if next_ts == latest_ts
                # df is already updated
                continue
            end
            for (this_tf_str, candles) in tf_candles
                if this_tf_str == tf_str
                    for cdl in candles
                        cdl_ts = apply(tf, first(cdl) |> dt)
                        if cdl_ts < latest_ts && cdl_ts == next_ts
                            tup = (cdl_ts, (pytofloat(cdl[idx]) for idx in 2:6)...)
                            push!(this_df, tup)
                            next_ts = cdl_ts
                        end
                    end
                    if next_ts + tf < latest_ts
                        @warn "ohlcv (candles): out of sync, resolving"
                        _ensure_ohlcv!(w, sym)
                    end
                end
            end
        end
        snap.py
    end
end

function _update_ohlcv_func_single(w, sym)
    view = _view(w)
    tf = _tfr(w)
    function ohlcv_wrapper_func(snap)
        if snap isa Exception
            @error "ohlcv (candles): exception" exception = snap
            return nothing
        elseif !islist(snap)
            @error "ohlcv (candles): unknown value" snap
            return nothing
        end
        df = get(view, sym, nothing)
        if isnothing(df) || isempty(df)
            @debug "ohlcv (candles): waiting for startup fetch" _module = LogOHLCVWatcher sym
            return nothing
        end
        latest_ts = apply(tf, now())
        next_ts::DateTime = _nextdate(df, tf)
        if next_ts == latest_ts
            # df is already updated
            return nothing
        end
        for cdl in snap
            cdl_ts = apply(tf, first(cdl) |> dt)
            if cdl_ts < latest_ts && cdl_ts == next_ts
                tup = (cdl_ts, (pytofloat(cdl[idx]) for idx in 2:6)...)
                push!(df, tup)
                next_ts = cdl_ts
            end
        end
        if next_ts + tf < latest_ts
            @warn "ohlcv (candles): out of sync, resolving"
            _ensure_ohlcv!(w, sym)
        end
        snap.py
    end
end

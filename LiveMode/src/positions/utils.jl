using .Instances: MarginInstance, raw, cash, cash!
using .Python: PyException, pyisinstance, pybuiltins, @pystr, pytryfloat, pytruth, pyconvert
using .Python.PythonCall: pyisTrue, Py, pyisnone
using .Misc.Lang: @lget!, Option
using .Executors.OrderTypes: ByPos
using .Executors: committed, marginmode, update_leverage!, liqprice!, update_maintenance!
using .Executors.Instruments: qc, bc
using .Executors.Instruments.Derivatives: sc
using .Instances:
    PositionOpen,
    PositionClose,
    position,
    reset!,
    isdust,
    liqprice!,
    entryprice!,
    entryprice,
    maintenance,
    maintenance!,
    posside,
    mmr,
    margin,
    collateral,
    margin!,
    initial!,
    additional!,
    addmargin!,
    liqprice,
    timestamp,
    timestamp!,
    maxleverage,
    notional,
    notional!,
    tier!
using Base: negate

_issym(py, sym) = pyisTrue(get_py(py, "symbol") == @pystr(sym))
_optposside(ai) =
    let p = position(ai)
        isnothing(p) ? nothing : posside(p)
    end

function _force_fetch(s, ai, sym, side; fallback_kwargs)
    resp = fetch_positions(s, ai; fallback_kwargs...)
    pos = if resp isa PyException
        return nothing
    elseif islist(resp)
        if isempty(resp)
            return nothing
        else
            for this in resp
                if _ccxtposside(this) == side && _issym(this, sym)
                    return this
                end
            end
        end
    end
end

_isold(snap, since) = !isnothing(since) && @something(pytodate(snap), since) < since
function live_position(
    s::LiveStrategy,
    ai,
    side=_optposside(ai);
    fallback_kwargs=(),
    since=nothing,
    force=false,
)
    data = get_positions(s, side)
    sym = raw(ai)
    tup = get(data, sym, nothing)
    if isnothing(tup) && force
        pos = _force_fetch(s, ai, sym, side; fallback_kwargs)
        if isdict(pos) && _issym(pos, sym)
            get(positions_watcher(s).attrs, :keep_info, false) || _deletek(pos, "info")
            date = @something pytodate(pos) now()
            tup = data[sym] = (date, notify=Base.Threads.Condition(), pos)
        end
    end
    while !isnothing(tup) && _isold(tup.pos, since)
        safewait(tup.notify)
        tup = get(data, sym, nothing)
    end
    tup isa NamedTuple ? tup.pos : nothing
end

get_py(v::Py, k) = v.get(@pystr(k))
get_py(v::Py, k, def) = v.get(@pystr(k), def)
get_float(v::Py, k) = v.get(@pystr(k)) |> pytofloat
get_bool(v::Py, k) = v.get(@pystr(k)) |> pytruth
get_time(v::Py, k) =
    let d = v.get(@pystr(k))
        @something pyconvert(Option{DateTime}, d) now()
    end
live_amount(lp::Py) = get_float(lp, "contracts")
live_entryprice(lp::Py) = get_float(lp, "entryPrice")
live_mmr(lp::Py, pos) =
    let v = get_float(lp, "maintenanceMarginPercentage")
        if v > ZERO
            v
        else
            mmr(pos)
        end
    end

const Pos =
    PosFields = NamedTuple(
        Symbol(f) => f for f in (
            "liquidationPrice",
            "initialMargin",
            "maintenanceMargin",
            "collateral",
            "entryPrice",
            "timestamp",
            "datetime",
            "lastUpdateTimestamp",
            "additionalMargin",
            "notional",
            "contracts",
            "symbol",
            "unrealizedPnl",
            "leverage",
            "id",
            "contractSize",
            "markPrice",
            "lastPrice",
            "marginMode",
            "marginRatio",
            "side",
            "hedged",
            "percentage",
        )
    )

live_side(v::Py) = get_py(v, "side", @pystr("")).lower()
_ccxtposside(::ByPos{Long}) = "long"
_ccxtposside(::ByPos{Short}) = "short"
_ccxtisshort(v::Py) = pyisTrue(live_side(v) == @pystr("short"))
_ccxtislong(v::Py) = pyisTrue(live_side(v) == @pystr("long"))
_ccxtposside(v::Py) =
    if _ccxtislong(v)
        Long()
    elseif _ccxtisshort(v)
        Short()
    else
        _ccxtpnlside(v)
    end
_ccxtposprice(ai, update) =
    let lp = get_float(update, Pos.lastPrice)
        if lp <= zero(DFT)
            lp = get_float(update, Pos.markPrice)
            if lp <= zero(DFT)
                lastprice(ai)
            else
                lp
            end
        else
            lp
        end
    end

function _ccxtpnlside(update)
    upnl = get_float(update, Pos.unrealizedPnl)
    liqprice = get_float(update, Pos.liquidationPrice)
    eprice = get_float(update, Pos.entryPrice)
    ifelse(upnl >= ZERO && liqprice < eprice, Long(), Short())
end

function get_side(update, p::Option{ByPos}=nothing)
    ccxt_side = get_py(update, Pos.side)
    if pyisnone(ccxt_side)
        if isnothing(p)
            @warn "Position side not provided, inferring from position state"
            _ccxtpnlside(update)
        else
            posside(p)
        end
    else
        let side_str = ccxt_side.lower()
            if pyisTrue(side_str == @pystr("short"))
                Short()
            elseif pyisTrue(side_str == @pystr("long"))
                Long()
            else
                @warn "Position side flag not valid, inferring from position state"
                _ccxtpnlside(update)
            end
        end
    end
end

function live_sync!(
    s::LiveStrategy,
    ai::MarginInstance,
    p::Option{ByPos},
    update::Py;
    amount=live_amount(update),
    ep_in=live_entryprice(update),
    commits=true,
)
    pside = get_side(update, p)
    pos = position(ai, pside)

    # check hedged mode
    get_bool(update, Pos.hedged) == ishedged(pos) ||
        @warn "Position hedged mode mismatch (local: $(pos.hedged))"
    @assert ishedged(pos) || !isopen(opposite(ai, pside)) "Double position open in NON hedged mode."
    this_time = get_time(update, "timestamp")
    pos.timestamp[] == this_time && return pos

    # Margin/hedged mode are immutable so just check for mismatch
    let mm = get_py(update, Pos.marginMode)
        pyisnone(mm) ||
            mm == @pystr(marginmode(pos)) ||
            @warn "Position margin mode mismatch (local: $(marginmode(pos)))"
    end

    # update cash, (always positive for longs, or always negative for shorts)
    cash!(pos, islong(pos) ? (amount |> abs) : (amount |> abs |> negate))
    # If the updated amount is "dust" the position should be considered closed, and to be reset
    pos_price = _ccxtposprice(ai, update)
    if isdust(ai, pos_price, pside)
        reset!(pos)
        return pos
    end
    pos.status[] = PositionOpen()
    ai.lastpos[] = pos
    dowarn(what, val) = @warn "Unable to sync $what from $(nameof(exchange(ai))), got $val"
    # price is always positive
    ep = pytofloat(ep_in)
    ep = if ep > zero(DFT)
        entryprice!(pos, ep)
        ep
    else
        entryprice!(pos, pos_price)
        dowarn("entry price", ep)
        pos_price
    end
    commits && let comm = committed(s, ai, pside)
        isapprox(committed(pos), comm) || commit!(pos, comm)
    end

    lev = get_float(update, "leverage")
    if lev > zero(DFT)
        leverage!(pos, lev)
    else
        dowarn("leverage", lev)
        lev = one(DFT)
    end
    ntl = let v = get_float(update, Pos.notional)
        if v > zero(DFT)
            notional!(pos, v)
            notional(pos)
        else
            let a = ai.asset
                spot_sym = "$(bc(a))/$(sc(a))"
                price = try
                    # try to use the price of the settlement cur
                    lastprice(spot_sym, exchange(ai))
                catch
                    # or fallback to price of quote cur
                    pos_price
                end
                v = price * cash(pos)
                notional!(pos, v)
                notional(pos)
            end
        end
    end
    @assert ntl > ZERO "Notional can't be zero"

    tier!(pos, ntl)
    lqp = get_float(update, Pos.liquidationPrice)
    liqprice_set = lqp > zero(DFT) && (liqprice!(pos, lqp); true)

    mrg = get_float(update, Pos.initialMargin)
    coll = get_float(update, Pos.collateral)
    adt = max(zero(DFT), coll - mrg)
    mrg_set = mrg > zero(DFT) && begin
        initial!(pos, mrg)
        additional!(pos, adt)
        true
    end
    mm = get_float(update, Pos.maintenanceMargin)
    mm_set = mm > zero(DFT) && (maintenance!(pos, mm); true)
    # Since we don't know if the exchange supports all position fields
    # try to emulate the ones not supported based on what is available
    _margin!() = begin
        margin!(pos; ntl, lev)
        additional!(pos, max(zero(DFT), coll - margin(pos)))
    end

    liqprice_set || begin
        liqprice!(
            pos,
            liqprice(pside, ep, lev, live_mmr(update, pos); additional=adt, notional=ntl),
        )
    end
    mrg_set || _margin!()
    mm_set || update_maintenance!(pos; mmr=live_mmr(update, pos))
    function higherwarn(whata, whatb, a, b)
        "($(raw(ai))) $whata ($(a)) can't be higher than $whatb $(b)"
    end
    @assert maintenance(pos) <= collateral(pos) higherwarn(
        "maintenance", "collateral", maintenance(pos), collateral(pos)
    )
    @assert liqprice(pos) <= entryprice(pos) || isshort(pside) higherwarn(
        "liquidation price", "entry price", liqprice(pos), entryprice(pos)
    )
    @assert committed(pos) <= abs(cash(pos)) higherwarn(
        "committment", "cash", committed(pos), cash(pos).value
    )
    @assert leverage(pos) <= maxleverage(pos) higherwarn(
        "leverage", "max leverage", leverage(pos), maxleverage(pos)
    )
    @assert pos.min_size <= notional(pos) higherwarn(
        "min size", "notional", pos.min_size, notional(pos)
    )
    timestamp!(pos, get_time(update, "timestamp"))
    return pos
end

function live_sync!(s::LiveStrategy, ai, p=position(ai); since=nothing, kwargs...)
    update = live_position(s, ai, posside(p); since)
    live_sync!(s, ai, p, update; kwargs...)
end

function live_pnl(s::LiveStrategy, ai, p::ByPos; force_resync=:auto, verbose=true)
    pside = posside(p)
    lp = live_position(s, ai::MarginInstance, pside)
    pos = position(ai, p)
    pnl = get_float(lp, Pos.unrealizedPnl)
    if iszero(pnl)
        amount = get_float(lp, "contracts")
        function dowarn(a, b)
            @warn "Position amount for $(raw(ai)) unsynced from exchange $(nameof(exchange(ai))) ($a != $b), resyncing..."
        end
        resync = false
        if amount > zero(DFT)
            if !isapprox(amount, abs(cash(pos)))
                verbose && dowarn(amount, abs(cash(pos).value))
                resync = true
            end
            ep = live_entryprice(lp)
            if !isapprox(ep, entryprice(pos))
                verbose && dowarn(amount, entryprice(pos))
                resync = true
            end
            if force_resync == :yes || (force_resync == :auto && resync)
                live_sync!(s, ai, pside, lp; commits=false)
            end
            Instances.pnl(pos, _ccxtposprice(ai, lp))
        else
            pnl
        end
    else
        pnl
    end
end

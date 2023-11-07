using .Data.Cache: save_cache, load_cache
using .Misc: user_dir, config_path

macro notfound(path)
    quote
        error("Strategy not found at $($(esc(path)))")
    end
end

function find_path(file, cfg)
    if !ispath(file)
        if isabspath(file)
            @notfound file
        else
            from_pwd = joinpath(pwd(), file)
            ispath(from_pwd) && return from_pwd
            from_user = joinpath(user_dir(), file)
            ispath(from_user) && return from_user
            from_cfg = joinpath(dirname(cfg.path), file)
            ispath(from_cfg) && return from_cfg
            from_proj = joinpath(dirname(Pkg.project().path), file)
            ispath(from_proj) && return from_proj
            @notfound file
        end
    end
    realpath(file)
end

function _file(src, cfg, is_project)
    file = if is_project
        file = joinpath(dirname(realpath(cfg.path)), "src", string(src, ".jl"))
        if ispath(file)
            file
        else
        end
    else
        @something get(attrs(cfg), "include_file", nothing) joinpath(
            user_dir(), "strategies", string(src, ".jl")
        )
    end
    if isnothing(file)
        file = get(cfg.sources, src, nothing)
        if isnothing(file)
            msg = if is_project
                "Strategy include file not found for project $src, \
                declare `include_file` manually in strategy config \
                or ensure `src/$src.jl is present. cfg: $(cfg.path) file: ($file)"
            else
                "Section `$src` does not declare an `include_file` and \
                section `sources` does not declare a `$src` key or \
                its value is not a valid file. cfg: $(cfg.path) file: $(file)"
            end
            throw(ArgumentError(msg))
        end
    end
    file
end

function _defined_marginmode(mod)
    try
        marginmode(mod.S)
    catch
        marginmode(mod.SC)
    end
end

_strat_load_checks(s::Strategy, config::Config) = begin
    @assert marginmode(s) == config.margin
    @assert execmode(s) == config.mode
    s[:verbose] = false
    s
end

function default_load(mod::Module, t::Type, config::Config)
    assets = invokelatest(mod.ping!, t, StrategyMarkets())
    sandbox = config.mode == Paper() ? false : config.sandbox
    s = Strategy(mod, assets; config, sandbox)
    _strat_load_checks(s, config)
end

function bare_load(mod::Module, t::Type, config::Config)
    syms = invokelatest(mod.ping!, t, StrategyMarkets())
    exc = Exchanges.getexchange!(config.exchange; sandbox=true)
    uni = AssetCollection(syms; load_data=false, timeframe=mod.TF, exc, config.margin)
    s = Strategy(mod, config.mode, config.margin, mod.TF, exc, uni; config)
    _strat_load_checks(s, config)
end

function strategy!(src::Symbol, cfg::Config)
    file = _file(src, cfg, false)
    isproject = if splitext(file)[2] == ".toml"
        project_file = find_path(file, cfg)
        path = find_path(file, cfg)
        name = string(src)
        Misc.config!(name; cfg, path, check=false)
        file = _file(src, cfg, true)
        true
    else
        project_file = nothing
        false
    end
    prev_proj = Base.active_project()
    path = find_path(file, cfg)
    parent = get(cfg.attrs, :parent_module, Main)
    @assert parent isa Module "loading: $parent is not symbol (module)"
    mod = if !isdefined(parent, src)
        @eval parent begin
            try
                let
                    using Pkg: Pkg
                    $isproject && begin
                        Pkg.activate($project_file; io=Base.devnull)
                        Pkg.instantiate(; io=Base.devnull)
                    end
                    include($path)
                    using .$src
                    if isinteractive() && isdefined(Main, :Revise)
                        Main.Revise.track($src, $path)
                    end
                    $src
                end
            finally
                $isproject && Pkg.activate($prev_proj; io=Base.devnull)
            end
        end
    else
        @eval parent $src
    end
    strategy!(mod, cfg)
end
_concrete(type, param) = isconcretetype(type) ? type : type{param}
function _strategy_type(mod, cfg)
    s_type = try
        mod.S
    catch
        if cfg.exchange == Symbol()
            if hasproperty(mod, :EXCID) && mod.EXCID != Symbol()
                cfg.exchange = mod.EXCID
            else
                error("loading: exchange not specified (neither in strategy nor in config)")
            end
        end
        try
            if hasproperty(mod, :EXCID) && mod.EXCID != cfg.exchange
                @warn "loading: overriding default exchange with config" mod.EXCID cfg.exchange
            end
            mod.SC{ExchangeID{cfg.exchange}}
        catch
            error("loading: strategy main type `S` or `SC` not defined in strategy module.")
        end
    end
    mode_type = s_type{typeof(cfg.mode)}
    margin_type = _concrete(mode_type, typeof(cfg.margin))
    _concrete(margin_type, typeof(cfg.qc))
end
function strategy!(mod::Module, cfg::Config)
    if isnothing(cfg.mode)
        cfg.mode = Sim()
    end
    def_mm = _defined_marginmode(mod)
    if isnothing(cfg.margin)
        cfg.margin = def_mm
    elseif def_mm != cfg.margin
        @warn "Mismatching margin mode" config = cfg.margin strategy = def_mm
    end
    s_type = _strategy_type(mod, cfg)
    strat_exc = nameof(exchangeid(s_type))
    # The strategy can have a default exchange symbol
    if cfg.exchange == Symbol()
        cfg.exchange = strat_exc
        if strat_exc == Symbol()
            @warn "Strategy exchange unset"
        end
    end
    if cfg.min_timeframe == tf"0s" # any zero tf should match
        cfg.min_timeframe = tf"1m" # default to 1 minute timeframe
        tfs = cfg.min_timeframes
        sort!(tfs)
        idx = searchsortedfirst(tfs, tf"1m")
        if length(tfs) < idx || tfs[idx] != tf"1m"
            insert!(tfs, idx, tf"1m")
        end
    end
    @assert nameof(s_type) isa Symbol "Source $src does not define a strategy name."
    @something invokelatest(mod.ping!, s_type, cfg, LoadStrategy()) try
        default_load(mod, s_type, cfg)
    catch
        nothing
    end bare_load(mod, s_type, cfg)
end

function strategy_cache_path()
    cache_path = user_dir()
    @assert ispath(cache_path) "Can't load strategy state, no directory at $cache_path"
    cache_path = joinpath(cache_path, "cache")
    mkpath(cache_path)
    cache_path
end

function _strategy_config(src, path; load, config_args...)
    if load
        cache_path = strategy_cache_path()
        cfg = load_cache(string(src); raise=false, cache_path)
        if !(cfg isa Config)
            @warn "Strategy state ($src) not found at $cache_path"
            Config(src, path; config_args...)
        else
            cfg
        end
    else
        Config(src, path; config_args...)
    end
end

function strategy(
    src::Union{Symbol,Module,String}, path::String=config_path(); load=false, config_args...
)
    cfg = _strategy_config(src, path; load, config_args...)
    strategy(src, cfg; save=load)
end

function strategy(src::Union{Symbol,Module,String}, cfg::Config; save=false)
    s = strategy!(src, cfg)
    save && save_strategy(s)
    s
end

function save_strategy(s)
    cache_path = @lget! attrs(s) :config_cache_path strategy_cache_path()
    save_cache(string(nameof(s)); raise=false, cache_path)
end

function _no_inv_contracts(exc::Exchange, uni)
    for ai in uni
        @assert something(get(exc.markets[ai.asset.raw], "linear", true), true) "Inverse contracts are not supported by SimMode."
    end
end

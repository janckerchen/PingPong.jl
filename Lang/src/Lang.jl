module Lang

using Distributed: @distributed
using Logging: with_logger, NullLogger

const Option{T} = Union{Nothing,T} where {T}

macro evalmod(files...)
    quote
        with_logger(NullLogger()) do
            for f in $files
                eval(:(include(joinpath(@__DIR__, $f))))
            end
        end
    end
end

macro parallel(flag, body)
    b = esc(body)
    db = esc(:(@distributed $body))
    quote
        if $(esc(flag))
            $db
        else
            $b
        end
    end
end

passkwargs(args...) = [Expr(:kw, a.args[1], a.args[2]) for a in args]

macro passkwargs(args...)
    kwargs = [Expr(:kw, a.args[1], a.args[2]) for a in args]
    return esc(:($(kwargs...)))
end

export passkwargs, @passkwargs

@doc """Get a value from a container that *should not contain* `nothing`, lazily evaluating the default value.
```julia
> @get Dict("a" => false) "a" (println("hello"); true)
false
> Lang.@get Dict("a" => false) "b" (println("hello"); true)
hello
true
```
"""
macro get(dict, k, expr)
    dict = esc(dict)
    expr = esc(expr)
    k = esc(k)
    :(@something get($dict, $k, nothing) $expr)
end

@doc "Lazy *get or set* for a container key-value pair that *should not contain* `nothing`."
macro lget!(dict, k, expr)
    dict = esc(dict)
    expr = esc(expr)
    k = esc(k)
    quote
        @something get($dict, $k, nothing) let v = $expr
            $dict[$k] = v
            v
        end
    end
end

@doc """Get the first available key from a container, or a default (last) value.
```julia
> @multiget Dict("k" => 1) "a" "b" false
false
> @multiget Dict("k" => 1, "b" => 2) "a" "b" false
2
```
"""
macro multiget(dict, args...)
    dict = esc(dict)
    if length(args) < 2
        throw(ArgumentError("Not enough args in macro call."))
    end
    expr = esc(args[end])
    result = :(@something)
    for k in args[begin:(end - 1)]
        push!(result.args, :(get($dict, $(esc(k)), nothing)))
    end
    push!(result.args, expr)
    result
end

@doc "Use this in loops instead of `@lget!`"
macro kget!(dict, k, expr)
    dict = esc(dict)
    expr = esc(expr)
    k = esc(k)
    quote
        if haskey($dict, $k)
            $dict[$k]
        else
            v = $expr
            $dict[$k] = v
            v
        end
    end
end

@doc "Define a new symbol with given value if it is not already defined."
macro ifundef(name, val, mod=__module__)
    name_var = esc(name)
    name_sym = esc(:(Symbol($(string(name)))))
    quote
        if isdefined($mod, $name_sym)
            $name_var = getproperty($mod, $name_sym)
        else
            $name_var = $val
        end
    end
end

@doc "Export all instances of an enum type."
macro exportenum(enums...)
    expr = quote end
    for enum in enums
        push!(
            expr.args,
            :(Core.eval(
                $__module__, Expr(:export, map(Symbol, instances($(esc(enum))))...)
            )),
        )
    end
    expr
end

@doc "Import all instances of an enum type."
macro importenum(T)
    ex = quote end
    mod = T.args[1]
    for val in instances(Core.eval(__module__, T))
        str = Meta.parse("import $mod.$val")
        ex = quote
            Core.eval($__module__, $str)
            $ex
        end
    end
    return ex
end

macro as(sym, val)
    s = esc(sym)
    v = esc(val)
    quote
        $s = $v
        true
    end
end

# FIXME: untested
@doc "Unroll expression `exp` for every element in `fields` assign each element to symbol defined by `asn`.

`exp` must use the name defined by `asn`(default to `el`) as the variable name of the loop."
macro unroll(exp, fields, asn=:el)
    ex = esc(exp)
    Expr(:block, (:($(esc(asn)) = $el; $ex) for el in fields.args)...)
end

@doc "`fromdict` tries to fill a _known_ `NamedTuple` from an _unknown_ `Dict`."
@generated function fromdict(tuple, key, di, kconvfunc=convert, convfunc=convert)
    params = Expr(:parameters)
    ex = Expr(:tuple, params)
    ttype = first(tuple.parameters)
    ktype = isempty(key.parameters) ? key : first(key.parameters)
    for (fi, ty) in zip(fieldnames(ttype), fieldtypes(ttype))
        p = Expr(:kw, fi, :(convfunc($ty, (di[kconvfunc($ktype, $(QuoteNode(fi)))]))))
        push!(params.args, p)
    end
    ex
end

@doc "Converts a struct into a named tuple."
function fromstruct(c::T) where {T}
    names = fieldnames(T)
    nt = NamedTuple{names,Tuple{fieldtypes(T)...}}
    t = (getfield(c, f) for f in names)
    nt(t)
end

macro sym_str(s)
    :(Symbol($s))
end

_asbool(v::Bool) = v
_asbool(v::String) = tryparse(Bool, v)
function _isdebug()
    @something _asbool(@something get(ENV, "JULIA_DEBUG", nothing) false) false
end

macro ifdebug(a, b=nothing)
    _isdebug() ? esc(a) : b
end

@doc "`errormonitor` wrapped `@async` call."
macro asyncm(expr)
    :(errormonitor(@async $(esc(expr))))
end

@doc "Sets property `prop` on object `a` to value `val` if `op(a.prop, val)` is `true`."
function ifproperty!(op, a, prop, val)
    op(getproperty(a, prop), val) && setproperty!(a, prop, val)
end
@doc "Sets key `k` on object `a` to value `val` if `op(a[prop], val)` is `true`."
function ifkey!(op, a, k, val)
    op(get!(a, k, val), val) && setindex!(a, val, k)
end

@doc "Notify a condition with locks."
safenotify(cond, args...; kwargs...) = begin
    lock(cond)
    notify(cond, args...; kwargs...)
    unlock(cond)
end
@doc "Wait a condition with locks."
safewait(cond) = begin
    lock(cond)
    wait(cond)
    unlock(cond)
end
@doc "Same as `@lock` but with `acquire` and `release`."
macro acquire(cond, code)
    quote
        temp = $(esc(cond))
        acquire(temp)
        try
            $(esc(code))
        catch e
            e
        finally
            release(temp)
        end
    end
end

export @kget!, @lget!
export passkwargs, @exportenum
export @as, @sym_str
export Option, @asyncm, @ifdebug

end

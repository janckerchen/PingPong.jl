@doc "Same as ccxt precision mode enums."
@enum ExcPrecisionMode excDecimalPlaces = 2 excSignificantDigits = 3 excTickSize = 4

abstract type Exchange{I} end
const OptionsDict = Dict{String,Dict{String,Any}}
@doc """The exchange type wraps a ccxt exchange instance. Some attributes frequently accessed
are copied over to avoid round tripping python. More attributes might be added in the future.
To instantiate an exchange call `getexchange!` or `setexchange!`.

"""
struct CcxtExchange{I<:ExchangeID} <: Exchange{I}
    py::Py
    id::I
    name::String
    precision::Vector{ExcPrecisionMode}
    timeframes::Set{String}
    markets::OptionsDict
    has::Dict{Symbol,Bool}
end

Exchange() = CcxtExchange{typeof(ExchangeID())}(pybuiltins.None)
function Exchange(x::Py)
    id = ExchangeID(x)
    name = pyisnone(x) ? "" : pyconvert(String, pygetattr(x, "name"))
    CcxtExchange{typeof(id)}(
        x, id, name, [excDecimalPlaces], Set(), OptionsDict(), Dict{Symbol,Bool}()
    )
end

Base.isempty(e::Exchange) = nameof(e.id) === Symbol()

@doc "The hash of an exchange object is reduced to its symbol (the function used to instantiate the object from ccxt)."
Base.hash(e::Exchange, u::UInt) = Base.hash(e.id, u)

@doc "Attributes not matching the `Exchange` struct fields are forwarded to the wrapped ccxt class instance."
function Base.getproperty(e::E, k::Symbol) where {E<:Exchange}
    if hasfield(E, k)
        if k == :precision
            getfield(e, k)[1]
        else
            getfield(e, k)
        end
    else
        !isempty(e) || throw("Can't access non instantiated exchange object.")
        getproperty(getfield(e, :py), k)
    end
end
function Base.propertynames(e::E) where {E<:Exchange}
    (fieldnames(E)..., propertynames(e.py)...)
end

has(exc::Exchange, s::Symbol) = haskey(getfield(exc, :has), s)
function Base.first(exc::Exchange, args::Vararg{Symbol})
    for a in args
        has(exc, a) && return getproperty(getfield(exc, :py), a)
    end
end

@doc "Updates the global exchange `exc` variable."
globalexchange!(new::Exchange) = begin
    global exc
    exc = new
    exc
end

@doc "Global var implicit exchange instance.

When working interactively, a global `exc` variable is available, updated through `globalexchange!`, which
is used as the default for some functions when the exchange argument is omitted."
exc = Exchange(pybuiltins.None)
@doc "Global var holding Exchange instances. Used as a cache."
const exchanges = Dict{Symbol,Exchange}()
@doc "Global var holding Sandbox Exchange instances. Used as a cache."
const sb_exchanges = Dict{Symbol,Exchange}()

Base.show(out::IO, exc::Exchange) = begin
    write(out, "Exchange: ")
    write(out, exc.name)
    write(out, " | ")
    write(out, "$(length(exc.markets)) markets")
    write(out, " | ")
    tfs = collect(exc.timeframes)
    write(out, "$(length(tfs)) timeframes")
end

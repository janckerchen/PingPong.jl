@nospecialize
module Instruments

struct Cash4
    name::Symbol
    value::Vector{Float64}
    Cash4(s, val::Real) = new(Symbol(s), [val])
end

@doc """A variable quantity of some currency.

```julia
> ca = c"USDT"
> typeof(ca)
# Instruments.Cash{:USDT}
```

"""
Cash = Cash4
Base.hash(c::Cash, h::UInt) = hash(c.name, h)
Base.setproperty!(c::Cash, ::Symbol, v::Real) = getfield(c, :value)[1] = v
Base.getproperty(c::Cash, s::Symbol) = begin
    if s === :value
        getfield(c, :value)[1]
    elseif s === :id
        c.name
    else
        getfield(c, s) ## throws
    end
end
@doc """Macro to instantiate `Cash` statically.

Don't put spaces between the id and the value.

```julia
> ca = c"USDT"1000
USDT: 1000.0
```
"""
macro c_str(sym, val=0)
    :($(Cash(Symbol(sym), val)))
end
Base.print(c::Cash) = print("$(c.name): $(c.value)")
Base.display(c::Cash) = print(c)

@doc "A symbol checked to be a valid quote currency."
const QuoteCurrency = Symbol
@doc "A symbol checked to be a valid base currency."
const BaseCurrency = Symbol

include("consts.jl")

has_punct(s::AbstractString) = !isnothing(match(r"[[:punct:]]", s))
abstract type AbstractAsset end

@doc """An `Asset` represents a parsed raw (usually ccxt) pair of base and quote currency.

- `raw`: The raw underlying string e.g. 'BTC/USDT'
- `bc`: base currency (Symbol)
- `qc`: quote currency (Symbol)
- `fiat`: if both the base and quote currencies match a known fiat symbol e.g. 'USDT/USDC'
- `leveraged`: if parsing matched a leveraged token e.g. 'ETH3L/USDT' or 'ETH3S/USDT'
- `unleveraged_bc`: a leveraged token with the `mod` removed, e.g. `ETH3L` => `ETH`

```julia
> asset = a"BTC/USDT"
> typeof(asset)
Asset{:BTC, :USDT}
end
```
"""
struct Asset5 <: AbstractAsset
    raw::SubString
    bc::BaseCurrency
    qc::QuoteCurrency
    fiat::Bool
    leveraged::Bool
    unleveraged_bc::BaseCurrency
    function Asset5(s::SubString, b::T, q::T) where {T<:AbstractString}
        B = Symbol(b)
        Q = Symbol(q)
        fiat = is_fiat_pair(b, q)
        lev = is_leveraged_pair(s)
        unlev = lev ? deleverage_pair(s; split=true)[1] : B
        new(s, B, Q, fiat, lev, Symbol(unlev))
    end
    Asset5(s::AbstractString) = parse(Asset, s)
end
Asset = Asset5

function Base.parse(::Type{Asset}, s::AbstractString)
    pair = split_pair(s)
    if length(pair) > 2 || has_punct(pair[1]) || has_punct(pair[2])
        throw(InexactError(:Asset, Asset, s))
    end
    Asset(SubString(s, 1, length(s)), pair[1], pair[2])
end
Base.hash(a::AbstractAsset) = hash((a.bc, a.qc))
Base.hash(a::AbstractAsset, h::UInt) = Base.hash((a.bc, a.qc), h)
Base.convert(::Type{String}, a::AbstractAsset) = a.raw
Base.show(buf::IO, a::AbstractAsset) = write(buf, "Asset($(a.qc)/$(a.bc))")
Base.display(a::AbstractAsset) = show(stdout, a)

const QuoteTuple = @NamedTuple{q::Symbol}
const BaseTuple = @NamedTuple{b::Symbol}
const BaseQuoteTuple = @NamedTuple{b::Symbol, q::Symbol}
const CurrencyTuple = Union{QuoteTuple,BaseTuple,BaseQuoteTuple}
Base.Broadcast.broadcastable(q::Asset) = Ref(q)
Base.in(a::Asset, t::QuoteTuple) = Base.isequal(a.qc, t.q)
Base.in(a::Asset, t::BaseTuple) = Base.isequal(a.bc, t.b)
Base.in(a::Asset, t::BaseQuoteTuple) = Base.isequal(a.bc, t.b) && Base.isequal(a.qc, t.q)
Base.isequal(a::Asset, s::String) = Base.isequal(a.raw, s)
Base.isequal(a::Asset, b::Asset) = a.qc == b.qc && a.bc == b.bc

isbase(a::AbstractAsset, b) = a.bc == b
isquote(a::AbstractAsset, q) = a.qc == q

const leverage_pair_rgx = r"(?:(?:BULL)|(?:BEAR)|(?:[0-9]+L)|(?:[0-9]+S)|(?:UP)|(?:DOWN)|(?:[0-9]+LONG)|(?:[0-9+]SHORT))([\/\-\_\.])"

@doc "Test if pair has leveraged naming."
is_leveraged_pair(pair) = !isnothing(match(leverage_pair_rgx, pair))
split_pair(pair::AbstractString) = split(pair, r"\/|\-|\_|\.")

@doc "Remove leveraged pair pre/suffixes from base currency."
@inline function deleverage_pair(pair::T; split=false, sep="/") where {T<:AbstractString}
    dlv = split_pair(replace(pair, leverage_pair_rgx => s"\1"))
    # HACK: assume that BEAR/BULL represent BTC
    if isempty(dlv[1])
        @warn "Deleveraging pair $pair failed, assuming base currency is BTC."
        dlv[1] = "BTC"
    end
    split ? dlv : join(dlv, sep)
end

function deleverage_qc(dlv::Vector{T}) where {T<:AbstractString}
    deleverage_pair(dlv; split=true)[1]
end
deleverage_qc(pair::AbstractString) = deleverage_pair(pair; split=true)[1]

@doc "Check if both base and quote are fiat currencies."
is_fiat_pair(b::T, q::T) where {T<:AbstractString} = begin
    b ∈ fiatnames && q ∈ fiatnames
end
is_fiat_pair(p::Vector{T}) where {T<:AbstractString} = is_fiat_pair(p[1], p[2])
is_fiat_pair(pair::AbstractString) = is_fiat_pair(split_pair(pair))

@doc """Parses `pair` to an `Asset` type.
```julia
> typeof(a"BTC/USDT")
Instruments.Asset
"""
macro a_str(pair)
    :($(parse(Asset, pair)))
end

@doc """Rewrites `sym` as a perpetual usdt symbol.
```julia
> pusdt"btc"
BTC/USDT:USDT
```
"""
macro pusdt_str(sym)
    :($(uppercase(sym) * "/USDT:USDT"))
end

export Cash, Asset, AbstractAsset
export is_fiat_pair, deleverage_pair, is_leveraged_pair
export @a_str, @c_str

include("derivatives.jl")

end # module Instruments

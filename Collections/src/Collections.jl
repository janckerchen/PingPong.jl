module Collections

using TimeTicks
using Lang: @lget!, MatchString
using Base.Enums: namemap
using Data.DataFrames
using Data.DataFramesMeta
using Data: load, zi
using Data.DFUtils
using OrderedCollections: OrderedDict
using Data.DataStructures: SortedDict
using Misc: Iterable, swapkeys
using ExchangeTypes
using Instruments: fiatnames, AbstractAsset, Asset, Cash
using Instruments.Derivatives
using Instances

# TYPENUM
@doc "A collection of assets instances, indexed by asset and exchange identifiers."
struct AssetCollection2
    data::DataFrame
    function AssetCollection2(
        df=DataFrame(;
            exchange=ExchangeID[], asset=AbstractAsset[], instance=AssetInstance[]
        ),
    )
        new(df)
    end
    function AssetCollection2(instances::Iterable{<:AssetInstance})
        AssetCollection2(
            DataFrame(
                (; exchange=inst.exchange.id, asset=inst.asset, instance=inst) for
                inst in instances;
                copycols=false,
            ),
        )
    end
    function AssetCollection2(
        assets::Union{Iterable{String},Iterable{<:AbstractAsset}};
        timeframe="1m",
        exc::Exchange,
        min_amount=1e-8,
    )
        if eltype(assets) == String
            assets = [parse(AbstractAsset, name) for name in assets]
        end

        tf = convert(TimeFrame, timeframe)
        function getInstance(ast::AbstractAsset)
            data = SortedDict(tf => load(zi, exc.name, ast.raw, timeframe))
            AssetInstance(ast; data, exc, min_amount)
        end
        instances = [getInstance(ast) for ast in assets]
        AssetCollection2(instances)
    end
end
AssetCollection = AssetCollection2

@enum AssetCollectionColumn exchange = 1 asset = 2 instance = 3
const AssetCollectionTypes = OrderedDict([
    exchange => ExchangeID, asset => AbstractAsset, instance => AssetInstance
])
const AssetCollectionColumns4 = Symbol.(keys(sort!(AssetCollectionTypes)))
AssetCollectionColumns = AssetCollectionColumns4
# HACK: const/types definitions inside macros can't be revised
if !isdefined(@__MODULE__, :AssetCollectionRow)
    const AssetCollectionRow = @NamedTuple{
        exchange::ExchangeID, asset::AbstractAsset, instance::AssetInstance
    }
end

using Instruments: isbase, isquote
function Base.getindex(ac::AssetCollection, i::ExchangeID, col=Colon())
    @view ac.data[ac.data.exchange .== i, col]
end
function Base.getindex(ac::AssetCollection, i::AbstractAsset, col=Colon())
    @view ac.data[ac.data.asset .== i, col]
end
function Base.getindex(ac::AssetCollection, i::AbstractString, col=Colon())
    @view ac.data[ac.data.asset .== i, col]
end
function Base.getindex(ac::AssetCollection, i::MatchString, col=Colon())
    v = @view ac.data[startswith.(getproperty.(ac.data.asset, :raw), uppercase(i.s)), :]
    isempty(v) && return v
    @view v[begin, col]
end
Base.getindex(ac::AssetCollection, i, i2, i3) = ac[i, i2][i3]

# TODO: this should use a macro...
@doc "Dispatch based on either base, quote currency, or exchange."
function bqe(df::DataFrame, b::T, q::T, e::T) where {T<:Symbol}
    isbase.(df.asset, b) && isquote.(df.asset, q) && df.exchange .== e
end
function bqe(df::DataFrame, ::Nothing, q::T, e::T) where {T<:Symbol}
    isquote(df.asset, q) && df.exchange .== e
end
function bqe(df::DataFrame, b::T, ::Nothing, e::T) where {T<:Symbol}
    isbase.(df.asset, b) && df.exchange .== e
end
function bqe(df::DataFrame, ::T, q::T, e::Nothing) where {T<:Symbol}
    isbase.(df.asset, b) && isquote.(df.asset, q)
end
bqe(df::DataFrame, ::Nothing, ::Nothing, e::T) where {T<:Symbol} = begin
    df.exchange .== e
end
function bqe(df::DataFrame, ::Nothing, q::T, e::Nothing) where {T<:Symbol}
    isquote.(df.asset, q)
end
bqe(df::DataFrame, b::T, ::Nothing, e::Nothing) where {T<:Symbol} = begin
    isbase.(df.asset, b)
end

function Base.getindex(
    ac::AssetCollection;
    b::Union{Symbol,Nothing}=nothing,
    q::Union{Symbol,Nothing}=nothing,
    e::Union{Symbol,Nothing}=nothing,
)
    idx = bqe(ac.data, b, q, e)
    @view ac.data[idx, :]
end

function prettydf(ac::AssetCollection; full=false)
    limit = full ? size(ac.data)[1] : displaysize(stdout)[1] - 1
    limit = min(size(ac.data)[1], limit)
    DataFrame(
        begin
            row = @view ac.data[n, :]
            (; cash=row.instance.cash, name=row.asset.raw, exchange=row.exchange.id)
        end for n in 1:limit
    )
end

Base.show(io::IO, ac::AssetCollection) = write(io, string(prettydf(ac)))

@doc "Returns a Dict{TimeFrame, DataFrame} of all the OHLCV dataframes present in the asset collection."
function flatten(ac::AssetCollection)::SortedDict{TimeFrame,Vector{DataFrame}}
    out = Dict()
    @eachrow ac.data for (tf, df) in :instance.data
        push!(@lget!(out, tf, DataFrame[]), df)
    end
    out
end

Base.first(ac::AssetCollection, a::AbstractAsset)::DataFrame =
    first(first(ac[a].instance).data)[2]

@doc "Makes a daterange that spans the common min and max dates of the collection."
function TimeTicks.DateRange(ac::AssetCollection, tf=nothing)
    m = typemin(DateTime)
    M = typemax(DateTime)
    for ai in ac.data.instance
        d_min = firstdate(first(values(ai.data)))
        d_min > m && (m = d_min)
        d_max = lastdate(last(ai.data).second)
        d_max < M && (M = d_max)
    end
    tf = @something tf first(ac.data[begin, :instance].data).first
    DateRange(m, M, tf)
end

Base.iterate(ac::AssetCollection) = iterate(ac.data.instance)
Base.iterate(ac::AssetCollection, s) = iterate(ac.data.instance, s)
Base.first(ac::AssetCollection) = first(ac.data.instance)
Base.last(ac::AssetCollection) = last(ac.data.instance)
Base.length(ac::AssetCollection) = nrow(ac.data)
Base.size(ac::AssetCollection) = size(ac.data)
Base.similar(ac::AssetCollection) = begin
    AssetCollection(similar.(ac.data.instance))
end

@doc "Checks that all assets in the universe match the cash."
iscashable(c::Cash, ac::AssetCollection) = begin
    for ai in ac
        if ai.asset.qc != nameof(c)
            return false
        end
        return true
    end
end

export AssetCollection, flatten, iscashable

end
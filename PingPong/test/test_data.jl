using Test
# using PingPong.Data.DFUtils
# include("env.jl")
# btc = first(s.universe, a"BTC/USDT")
#

test_zarrinstance() = begin
    zi = Data.zilmdb()
    @test zi isa ZarrInstance
    @test zi.store isa Data.LMDBDictStore
    @test startswith(zi.store.a.env.path, Data.DATA_PATH)
    zi
end


function test_save_json(zi=nothing, key="coingecko/markets/all")
    @eval begin
        using JSON
        using Mmap
        da = Data
    end
    data = JSON.parsefile("test/stubs/cg_markets.json")
    if isnothing(zi)
        zi = zilmdb()
    end
    za, existing = da._get_zarray(
        zi, key, (length(data), 2); type=String, overwrite=true, reset=true
    )
    @test size(za) == (length(data), 2)
    @test existing isa Bool
    v = [[(v["last_updated"]), JSON.json(v)] for v in values(data)]
    v = reduce(hcat, v) |> permutedims
    za[:, :] = v[:, :]
    n = length(data)
    for x in (1, n ÷ 2, n), y in (1, 2)
        @test za[x, y] == v[x, y]
    end
end

test_zarray_save(zi) = begin
    sz = (123, 3)
    k = string(rand())
    z, existing = da._get_zarray(
        zi, k, sz; type=String, overwrite=true, reset=true
    )
    @test !existing
    @test z isa ZArray
    @test eltype(z) == String
    @test length(z) == reduce(*, sz)
    @test size(z) == sz
    return z
end

test_data() = @testset "data" begin
    @eval begin
        using PingPong.Data
        da = Data
        using Data.Zarr
        za = Zarr
    end
    zi = test_zarrinstance()
    test_zarray_save(zi)
    test_save_json(zi)
end
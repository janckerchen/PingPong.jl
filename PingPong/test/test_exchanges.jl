using Test

exc_sym = :kucoin
test_exch() = @test setexchange!(:kucoin).name == "KuCoin"
_exchange_id() = begin
    getexchange!(exc_sym)
    exc_sym ∈ keys(ExchangeTypes.exchanges)
end
_exchange_pairs() = begin
    @eval begin
        using PingPong.Exchanges: marketsid
        const getpairs = PingPong.Exchanges.marketsid
        prs = getpairs()
    end
    length(prs) > 0
end

_exchange_sbox() = begin
    @eval using PingPong.Exchanges
    @assert !issandbox()
    sandbox!()
    @assert issandbox()
    sandbox!(; flag=false)
    @assert !issandbox()
    ratelimit!()
end

test_exchanges() = @testset "exchanges" begin
    test_exch()
    @test _exchange_id()
    @test _exchange_pairs()
    @test _exchange_sbox()
end
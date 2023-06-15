include("env.jl")


loadstrat!(strat=:ExampleMargin) = @eval begin
    s = st.strategy($(QuoteNode(strat)))
    fill!(s.universe, s.timeframe, config.timeframes[(begin + 1):end]...)
    dostub!()
    eth = s.universe[m"eth"].instance
end
loadstrat!()


using Instruments: compactnum as cnum

function _printtrades(io, o)
    hasproperty(o.attrs, :trades) && begin
        write(io, "Trades: ")
        write(io, string(length(o.attrs.trades)))
    end
end
function _printcommitted(io, o)
    hasproperty(o.attrs, :committed) && begin
        write(io, "\nCommitted: ")
        write(io, string(cnum(o.attrs.committed)))
    end
end
_printfilled(io, o) = hasproperty(o.attrs, :filled) && begin
    write(io, "\nFilled: ")
    write(io, cnum(o.attrs.filled[]))
end

function Base.show(io::IO, o::Order)
    write(io, split(string(ordertype(o)), ".")[(begin + 1):end]...)
    write(io, "\n")
    write(io, string(o.asset))
    write(io, "(")
    write(io, string(o.exc))
    write(io, "): amount~ ")
    write(io, string(cnum(o.amount)))
    write(io, " @ ")
    write(io, string(cnum(o.price)))
    write(io, " ~price\n")
    _printtrades(io, o)
    _printcommitted(io, o)
    _printfilled(io, o)
    write(io, "\nDate: ")
    write(io, string(o.date))
    write(io, "\n")
end

function Base.show(io::IO, t::Trade)
    write(io, "Trade: ")
    write(io, cnum(t.amount))
    write(io, " at ")
    write(io, cnum(abs(t.size / t.amount)))
    write(io, " (size $(cnum(t.size))) ")
    write(io, string(t.date))
    write(io, "\n")
    show(io, t.order)
end

_verb(o::BuyOrder) = "Bought "
_verb(o::SellOrder) = "Sold "

Base.display(o::Order) = begin
    write(stdout, _verb(o))
    write(stdout, cnum(o.amount))
    write(stdout, " ")
    write(stdout, o.asset.bc)
    write(stdout, " on ")
    write(stdout, string(o.exc))
    write(stdout, " priced at ")
    write(stdout, cnum(o.price))
    write(stdout, " ")
    write(stdout, o.asset.qc)
    write(stdout, "\n")
end

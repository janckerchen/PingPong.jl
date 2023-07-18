using PythonCall:
    Py, pynew, pydict, pyimport, pyexec, pycopy!, pyisnull, pybuiltins, pyconvert
using Dates: Period, Second
using ThreadPools: @tspawnat

@kwdef struct PythonAsync
    pyaio::Py = pynew()
    pyuv::Py = pynew()
    pythreads::Py = pynew()
    pyrunner::Py = pynew()
    pyloop::Py = pynew()
    pycoro_type::Py = pynew()
    task::Ref{Task} = Ref{Task}()
end

const gpa = PythonAsync()

function isinitialized_async(pa::PythonAsync)
    !pyisnull(pa.pyaio)
end

function Base.copyto!(pa_to::PythonAsync, pa_from::PythonAsync)
    if pyisnull(pa_to.pyaio) && !pyisnull(pa_from.pyaio)
        for f in fieldnames(PythonAsync)
            pycopy!(getfield(pa_to, f), getfield(pa_from, f))
        end
        true
    else
        false
    end
end

function _async_init(pa::PythonAsync)
    isinitialized_async(pa) && return nothing
    copyto!(pa, gpa) && return nothing
    if pyisnull(pa.pyaio)
        pycopy!(pa.pyaio, pyimport("asyncio"))
        pycopy!(pa.pyuv, pyimport("uvloop"))
        pycopy!(pa.pythreads, pyimport("threading"))
        py_start_loop(pa)
        if pyisnull(gpa.pyaio)
            for f in fieldnames(PythonAsync)
                let v = getfield(gpa, f)
                    if v isa Py
                        pycopy!(v, getfield(pa, f))
                    elseif f == :task
                        isassigned(v) && (pa.task[] = v[])
                    else
                        error()
                    end
                end
            end
        end
    end
    copyto!(gpa, pa)
    @assert !pyisnull(gpa.pyaio)
end

function py_start_loop(pa::PythonAsync)
    pyaio = pa.pyaio
    pyuv = pa.pyuv
    pyrunner = pa.pyrunner
    pyloop = pa.pyloop
    pycoro_type = pa.pycoro_type

    @assert !pyisnull(pyaio)
    @assert pyisnull(pyloop) || !Bool(pyloop.is_running())

    pycopy!(pycoro_type, pyimport("types").CoroutineType)
    pycopy!(pyrunner, pyaio.Runner(; loop_factory=pyuv.new_event_loop))
    pycopy!(pyloop, pyrunner.get_loop())
    pa.task[] = @async pyrunner.run(async_jl_func()())
    atexit(pyloop_stop_fn(pa))
end

pyloop_stop_fn(pa) = begin
    fn() = begin
        pyisnull(pa.pyloop) || pa.pyloop.stop()
        try
            wait(pa.task[])
        catch
        end
    end
    fn
end

# FIXME: This doesn't work if we pass `args...; kwargs...`
macro pytask(code)
    @assert code.head == :call
    Expr(:call, :pytask, esc(code.args[1]), esc.(code.args[2:end])...)
end

# FIXME: This doesn't work if we pass `args...; kwargs...`
macro pyfetch(code)
    @assert code.head == :call
    Expr(:call, :pyfetch, esc(code.args[1]), :(Val(:fut)), esc.(code.args[2:end])...)
end

function pyschedule(coro::Py)
    if pyisinstance(coro, Python.gpa.pycoro_type)
        gpa.pyaio.run_coroutine_threadsafe(coro, gpa.pyloop)
    end
end

_isfutdone(fut::Py) = pyisnull(fut) || let v = fut.done()
    Bool(v)
end

pywait_fut(fut::Py) = begin
    # id = rand()
    # @info "waiting fut $(id)"
    while !_isfutdone(fut)
        sleep(0.01)
    end
    # @info "fut $id done!"
end
pytask(coro::Py, ::Val{:coro}) = begin
    let fut = pyschedule(coro)
        @async begin
            pywait_fut($fut)
            $fut.result()
        end
    end
end
pytask(coro::Py, ::Val{:fut})::Tuple{Py,Union{Py,Task}} = begin
    fut = pyschedule(coro)
    (fut, @async if _isfutdone(fut)
        fut.result()
    else
        (pywait_fut($fut); $fut.result())
    end)
end
pytask(f::Py, args...; kwargs...) = pytask(f(args...; kwargs...), Val(:coro))
function pytask(f::Py, ::Val{:fut}, args...; kwargs...)
    pytask(f(args...; kwargs...), Val(:fut))
end
pycancel(fut::Py) = pyisnull(fut) || !pyisnull(gpa.pyloop.call_soon_threadsafe(fut.cancel))
function pyfetch(f::Py, args...; kwargs...)
    let (fut, task) = pytask(f(args...; kwargs...), Val(:fut))
        try
            fetch(task)
        catch e
            if e isa TaskFailedException
                task.result
            else
                istaskdone(task) || (pycancel(fut); wait(task))
                rethrow(e)
            end
        end
    end
end
function pyfetch(f::Py, ::Val{:try}, args...; kwargs...)
    try
        fut, task = pytask(f, Val(:fut), args...; kwargs...)
        try
            fetch(task)
        catch e
            if e isa TaskFailedException
                task.result
            else
                istaskdone(task) || (pycancel(fut); wait(task))
                rethrow(e)
            end
        end
    catch e
        e
    end
end

pyfetch(f::Function, args...; kwargs...) = fetch(@async(f(args...; kwargs...)))

function pyfetch_timeout(
    f1::Py, f2::Union{Function,Py}, timeout::Period, args...; kwargs...
)
    coro = gpa.pyaio.wait_for(f1(args...; kwargs...); timeout=Second(timeout).value)
    (fut, task) = pytask(coro, Val(:fut))
    try
        fetch(task)
    catch e
        if e isa TaskFailedException
            pyfetch(f2, args...; kwargs...)
        else
            istaskdone(task) || (pycancel(fut); wait(task))
            rethrow(e)
        end
    end
end

# function isrunning_func(running)
#     @pyexec (running) => """
#     global jl, jlrunning
#     import juliacall as jl
#     jlrunning = running
#     def isrunning(fut):
#         if fut.done():
#             jlrunning[0] = False
#     """ => isrunning
# end

# @doc "Main async loop function, sleeps indefinitely and closes loop on exception."
# function async_main_func()
#     code = """
#     global asyncio, inf
#     import asyncio
#     from math import inf
#     async def main():
#         try:
#             await asyncio.sleep(inf)
#         finally:
#             asyncio.get_running_loop().stop()
#     """
#     pyexec(NamedTuple{(:main,),Tuple{Py}}, code, pydict()).main
# end

function async_jl_func()
    code = """
    global asyncio, inf, juliacall, Main, jlyield
    import asyncio
    import juliacall
    from math import inf
    from juliacall import Main
    jlyield = getattr(Main, "yield")
    jlsleep = getattr(Main, "sleep")
    async def main():
        try:
            while True:
                await asyncio.sleep(1e-3)
                jlsleep(1e-3)
        finally:
            asyncio.get_running_loop().stop()
    """
    pyexec(NamedTuple{(:main,),Tuple{Py}}, code, pydict()).main
end

export pytask, pyfetch, pycancel, @pytask, @pyfetch, pyfetch_timeout

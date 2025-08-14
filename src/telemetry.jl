# ---------------------------
# Query hook for telemetry/benchmarks (no-op by default)
const onQueryHook = Ref{Function}((args...)->nothing)

"""
    setOnQuery!(f::Function)::Nothing

Install a callback invoked on every `executeQuery` call.
Signature:
    f(sql::AbstractString, params::Vector{Any}, meta::NamedTuple)
Where `meta` includes: `isSelect::Bool`, `useTransaction::Bool`.
"""
function setOnQuery!(f::Function)::Nothing
    onQueryHook[] = f
    return nothing
end

"""
    clearOnQuery!()::Nothing

Remove the current query hook (restores no-op).
"""
function clearOnQuery!()::Nothing
    onQueryHook[] = (args...)->nothing
    return nothing
end

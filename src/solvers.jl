using LinearAlgebra: qr, I, norm
using LowRankApprox: pqrfact
using IterativeSolvers
using .BayesianLinear
using LinearAlgebra: SVD, svd
using ActiveSetPursuit

@doc raw"""
`struct QR` : linear least squares solver, using standard QR factorisation; 
this solver computes 
```math 
 θ = \arg\min \| A \theta - y \|^2 + \lambda \| P \theta \|^2
```
Constructor
```julia
ACEfit.QR(; lambda = 0.0, P = nothing)
``` 
where 
* `λ` : regularisation parameter 
* `P` : right-preconditioner / tychonov operator
"""
struct QR
    lambda::Number
    P::Any
end

QR(; lambda = 0.0, P = I) = QR(lambda, P)

function solve(solver::QR, A, y)
    if solver.lambda == 0
        AP = A
        yP = y
    else
        AP = [A; solver.lambda * solver.P]
        yP = [y; zeros(eltype(y), size(A, 2))]
    end
    return Dict{String, Any}("C" => qr(AP) \ yP)
end

@doc raw"""
`struct RRQR` : linear least squares solver, using rank-revealing QR 
factorisation, which can sometimes be more robust / faster than the 
standard regularised QR factorisation. This solver first transforms the 
parameters ``\theta_P = P \theta``, then solves
```math 
 θ = \arg\min \| A P^{-1} \theta_P - y \|^2
```
where the truncation tolerance is given by the `rtol` parameter, and 
finally reverses the transformation. This uses the `pqrfact` of `LowRankApprox.jl`; 
For further details see the documentation of 
[`LowRankApprox.jl`](https://github.com/JuliaMatrices/LowRankApprox.jl#qr-decomposition).

Crucially, note that this algorithm is *not deterministic*; the results can change 
slightly between applications.

Constructor
```julia
ACEfit.RRQR(; rtol = 1e-15, P = I)
``` 
where 
* `rtol` : truncation tolerance
* `P` : right-preconditioner / tychonov operator
"""
struct RRQR
    rtol::Number
    P::Any
end

RRQR(; rtol = 1e-15, P = I) = RRQR(rtol, P)

function solve(solver::RRQR, A, y)
    AP = A / solver.P
    θP = pqrfact(AP, rtol = solver.rtol) \ y
    return Dict{String, Any}("C" => solver.P \ θP)
end

@doc raw"""
LSQR
"""
struct LSQR
    damp::Number
    atol::Number
    conlim::Number
    maxiter::Integer
    verbose::Bool
    P::Any
end

function LSQR(; damp = 5e-3, atol = 1e-6, conlim = 1e8, maxiter = 100000, verbose = false,
              P = nothing)
    LSQR(damp, atol, conlim, maxiter, verbose, P)
end

function solve(solver::LSQR, A, y)
    @warn "Need to apply preconditioner in LSQR."
    println("damp  ", solver.damp)
    println("atol  ", solver.atol)
    println("maxiter  ", solver.maxiter)
    c, ch = lsqr(A, y; damp = solver.damp, atol = solver.atol, conlim = solver.conlim,
                 maxiter = solver.maxiter, verbose = solver.verbose, log = true)
    println(ch)
    println("relative RMS error  ", norm(A * c - y) / norm(y))
    return Dict{String, Any}("C" => c)
end

@doc raw"""
`struct BLR` : Bayesian linear regression

    Refer to bayesianlinear.jl (for now) for kwarg definitions.
"""
struct BLR
    kwargs::Dict{Any,Any}
end

function BLR(; kwargs...)
    return BLR(Dict(kwargs))
end

function solve(solver::BLR, A, y)
    return bayesian_linear_regression(A, y; solver.kwargs...)
end

@doc raw"""
SKLEARN_BRR
"""
struct SKLEARN_BRR
    tol::Number
    max_iter::Integer
end

function SKLEARN_BRR(; tol = 1e-3, max_iter = 300)
    @warn "SKLearn will transition to MLJ in future, please upgrade your script to reflect this."
    SKLEARN_BRR(tol, max_iter)
end

# solve(solver::SKLEARN_BRR, ...) is implemented in ext/

@doc raw"""
SKLEARN_ARD
"""
struct SKLEARN_ARD
    max_iter::Integer
    tol::Number
    threshold_lambda::Number
end

function SKLEARN_ARD(; max_iter = 300, tol = 1e-3, threshold_lambda = 10000)
    @warn "SKLearn will transition to MLJ in future, please upgrade your script to reflect this."
    SKLEARN_ARD(max_iter, tol, threshold_lambda)
end

# solve(solver::SKLEARN_ARD, ...) is implemented in ext/

@doc raw"""
`struct TruncatedSVD` : linear least squares solver for approximately solving 
```math 
 θ = \arg\min \| A \theta - y \|^2 
```
- transform  $\tilde\theta  = P \theta$
- perform svd on $A P^{-1}$
- truncate svd at `rtol`, i.e. keep only the components for which $\sigma_i \geq {\rm rtol} \max \sigma_i$
- Compute $\tilde\theta$ from via pseudo-inverse
- Reverse transformation $\theta = P^{-1} \tilde\theta$

Constructor
```julia
ACEfit.TruncatedSVD(; rtol = 1e-9, P = I)
``` 
where 
* `rtol` : relative tolerance
* `P` : right-preconditioner / tychonov operator
"""
struct TruncatedSVD
    rtol::Number
    P::Any
end

TruncatedSVD(; rtol = 1e-9, P = I) = TruncatedSVD(rtol, P)

function trunc_svd(USV::SVD, Y, rtol)
    U, S, V = USV # svd(A)
    Ikeep = findall(x -> x > rtol, S ./ maximum(S))
    U1 = @view U[:, Ikeep]
    S1 = S[Ikeep]
    V1 = @view V[:, Ikeep]
    return V1 * (S1 .\ (U1' * Y))
end

function solve(solver::TruncatedSVD, A, y)
    AP = A / solver.P
    print("Truncted SVD: perform svd ... ")
    USV = svd(AP)
    print("done. truncation ... ")
    θP = trunc_svd(USV, y, solver.rtol)
    println("done.")
    return Dict{String, Any}("C" => solver.P \ θP)
end


@doc raw"""
`struct ASP` : Active Set Pursuit solver
    solves the optimization problem using either the basic or smart homotopy approach.
    ```math 
    \max_{y} \left( b^T y - \frac{1}{2} λ y^T y \right)
    ```
        subject to
        
    ```math
        \|A^T y\|_{\infty} \leq 1.
    ```
    * Input
    * `A` : `m`-by-`n` matrix.
    * `b` : `m`-vector.
    * `Aval` : `p`-by-`n` validation matrix (only for smart mode).
    * `bval` : `p`- validation vector (only for smart mode).

    * Solver parameters
    * `min_lambda` : Minimum value for `λ`. Defaults to zero if not provided.
    * `loglevel` : Logging level.
    * `itnMax` : Maximum number of iterations.
    * `actMax` : Maximum number of active constraints.
    * `mode` : Either `:basic` or `:smart`.

    Constructor
    ```julia
    ACEfit.ASPCombined(; P = I, select, mode, params)
    ``` 
    where 
    - `P` : right-preconditioner / tychonov operator
    - `select`: Selection mode for the final solution.
    - `params`: The solver parameters, passed as named arguments.
"""
struct ASP
    P::Any
    select::Tuple
    mode::Symbol
    params::NamedTuple
end

function ASP(; P = I, select, mode=:basic, params...)
    params_tuple = NamedTuple(params)
    return ASP(P, select, mode, params_tuple)
end

function solve(solver::ASP, A, y, Aval=nothing, yval=nothing)
    # Apply preconditioning
    AP = A / solver.P
    
    tracer = asp_homotopy(AP, y; solver.params[1]...)
    q = length(tracer)
    new_tracer = Vector{NamedTuple{(:solution, :λ), Tuple{Any, Any}}}(undef, q)

    for i in 1:q
        new_tracer[i] = (solution = solver.P \ tracer[i][1], λ = tracer[i][2])
    end

    if solver.mode == :basic
        xs, in = select_solution(new_tracer, solver, A, y)
    elseif solver.mode == :smart
        xs, in = select_smart(new_tracer, solver, Aval, yval)
    else
        @error("Unknown mode: $solver.mode")
    end

    println("done.")
    return Dict("C" => xs, "path" => new_tracer, "nnzs" => length((new_tracer[in][:solution]).nzind) )
end

function select_solution(tracer, solver, A, y)
    criterion, threshold = solver.select
    
    if criterion == :final
        return tracer[end][:solution], length(tracer)

    elseif criterion == :byerror
        errors = [norm(A * t[:solution] - y) for t in tracer]
        min_error = minimum(errors)
        
        for (i, error) in enumerate(errors)
            if error <= threshold * min_error
                return tracer[i][:solution], i
            end
        end
    elseif criterion == :bysize
        for i in 1:length(tracer)
            if length((tracer[i][:solution]).nzind) == threshold
                return tracer[i][:solution], i
            end
        end
    else
        @error("Unknown selection criterion: $criterion")
    end
end


function select_smart(tracer, solver, Aval,yval)

    best_metric = Inf
    best_iteration = 0
    validation_metric = 0
    q = length(tracer)
    errors = [norm(Aval * t[:solution] - yval) for t in tracer]
    nnzss = [(t[:solution]).nzind for t in tracer]
    best_iteration = argmin(errors)
    validation_metric = errors[best_iteration]
    validation_end = norm(Aval * tracer[end][:solution] - yval)

    if validation_end < validation_metric #make sure to check the last one too in case q<<100
        best_iteration = q
    end

    criterion, threshold = solver.select
    
    if criterion == :val
        return tracer[best_iteration][:solution], best_iteration

    elseif criterion == :byerror
        for (i, error) in enumerate(errors)
            if error <= threshold * validation_metric
                return tracer[i][:solution], i
            end
        end

    elseif criterion == :bysize
        first_index = findfirst(sublist -> threshold in sublist, nnzss)
        relevant_errors = errors[1:first_index - 1] 
        min_error = minimum(relevant_errors)
        min_error_index = findfirst(==(min_error), relevant_errors)
        return tracer[min_error_index][:solution], min_error_index

    else
        @error("Unknown selection criterion: $criterion")
    end
end

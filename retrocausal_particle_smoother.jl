#!/usr/bin/env julia
# retrocausal_particle_smoother.jl
# Fixed‑lag retrocausal particle smoother with golden‑ratio weights.
# Uses ESS‑controlled resampling, log‑space backward pass, vectorised transition.

using LinearAlgebra
using Random
using Plots

# ============================================================
# Golden‑ratio constants
# ============================================================
const φ = (1 + √5)/2
const α = 1/φ          # 0.618
const β = 1/φ^2        # 0.382
const LAG = round(Int, 10/φ)   # 6

# ============================================================
# Helper: logsumexp (stable)
# ============================================================
function logsumexp(x::Vector{Float64})
    m = maximum(x)
    return m + log(sum(exp.(x .- m)))
end

# ============================================================
# Nonlinear state‑space model (univariate growth model)
# ============================================================
function state_transition(x::Real, t::Int)
    return 0.5*x + 25*x/(1 + x^2) + 8*cos(1.2*t)
end

function measurement_function(x::Real)
    return x^2 / 20
end

function generate_data(T::Int, Q::Real=1.0, R::Real=1.0, x0::Real=0.1)
    x_true = zeros(T)
    y = zeros(T)
    x_true[1] = x0
    for t in 2:T
        x_true[t] = state_transition(x_true[t-1], t-1) + sqrt(Q)*randn()
    end
    for t in 1:T
        y[t] = measurement_function(x_true[t]) + sqrt(R)*randn()
    end
    return x_true, y
end

# ============================================================
# Systematic resampling (returns indices)
# ============================================================
function systematic_resample(weights::Vector{Float64})
    N = length(weights)
    cumsum = accumulate(+, weights)
    u = (rand() + (0:N-1)) / N
    indices = zeros(Int, N)
    j = 1
    for i in 1:N
        while u[i] > cumsum[j]
            j += 1
        end
        indices[i] = j
    end
    return indices
end

# ============================================================
# Effective sample size (ESS)
# ============================================================
function effective_sample_size(weights::Vector{Float64})
    return 1.0 / sum(weights.^2)
end

# ============================================================
# Bootstrap particle filter (one step, with ESS resampling)
# ============================================================
function bootstrap_step(particles::Vector{Float64}, y::Real, t::Int, Q::Real, R::Real,
                        ess_threshold::Real=0.5)
    N = length(particles)
    # Predict: transition
    for i in 1:N
        particles[i] = state_transition(particles[i], t-1) + sqrt(Q)*randn()
    end
    # Update weights (log domain for stability)
    log_weights = zeros(N)
    for i in 1:N
        y_pred = measurement_function(particles[i])
        log_weights[i] = -0.5 * ((y - y_pred)^2 / R + log(2π*R))
    end
    max_log = maximum(log_weights)
    weights = exp.(log_weights .- max_log)
    weights ./= sum(weights)

    # Filtered mean
    filtered_mean = sum(weights .* particles)

    # Resample if ESS below threshold
    ess = effective_sample_size(weights)
    if ess / N < ess_threshold
        indices = systematic_resample(weights)
        particles = particles[indices]
        weights = fill(1.0/N, N)
    end

    return particles, weights, filtered_mean
end

# ============================================================
# Fixed‑lag particle smoother (log‑space backward pass, vectorised)
# ============================================================
function fixed_lag_smoother(particles_window::Vector{Vector{Float64}},
                            weights_window::Vector{Vector{Float64}},
                            times_window::Vector{Int}, Q::Real)
    T_win = length(particles_window)
    N = length(particles_window[1])
    # Forward filtered weights are already stored (normalised)
    # Backward pass in log space
    log_smoothed_weights = [zeros(N) for _ in 1:T_win]
    # Last time: smoothed = filtered
    log_smoothed_weights[end] = log.(weights_window[end] .+ 1e-300)

    for t in T_win-1:-1:1
        part_t = particles_window[t]
        part_tp1 = particles_window[t+1]
        log_w_fwd = log.(weights_window[t] .+ 1e-300)
        log_w_smooth_next = log_smoothed_weights[t+1]
        time_idx = times_window[t]   # time index for transition

        log_w_smooth = zeros(N)
        for i in 1:N
            mu = state_transition(part_t[i], time_idx)
            # log transition from i to all j
            diff = part_tp1 .- mu
            log_trans = -0.5 * (diff.^2 / Q + log(2π*Q))
            # log( w_smooth_next[j] * exp(log_trans) ) = log_w_smooth_next[j] + log_trans
            # Sum over j using logsumexp
            log_sum = logsumexp(log_w_smooth_next + log_trans)
            log_w_smooth[i] = log_w_fwd[i] + log_sum
        end
        # Normalise in log space
        max_log = maximum(log_w_smooth)
        w_smooth = exp.(log_w_smooth .- max_log)
        w_smooth ./= sum(w_smooth)
        log_smoothed_weights[t] = log.(w_smooth .+ 1e-300)
    end
    # Smoothed mean for the first time in window
    smoothed_mean = sum(particles_window[1] .* exp.(log_smoothed_weights[1]))
    return smoothed_mean
end

# ============================================================
# Main simulation
# ============================================================
function main()
    T = 200
    N_particles = 1000
    Q = 1.0
    R = 1.0

    x_true, y = generate_data(T, Q, R)

    # Initial particles
    Random.seed!(123)
    particles = sqrt(10) * randn(N_particles)
    weights = fill(1.0/N_particles, N_particles)

    # Buffers for sliding window
    window_particles = Vector{Vector{Float64}}()
    window_weights = Vector{Vector{Float64}}()
    window_times = Vector{Int}()

    filtered_means = zeros(T)
    retro_means = fill(NaN, T)

    for t in 1:T
        # Filter step
        particles, weights, filtered_mean = bootstrap_step(particles, y[t], t, Q, R)
        filtered_means[t] = filtered_mean

        # Store in window
        push!(window_particles, copy(particles))
        push!(window_weights, copy(weights))
        push!(window_times, t)

        # Keep window size at most LAG+1
        if length(window_particles) > LAG + 1
            popfirst!(window_particles)
            popfirst!(window_weights)
            popfirst!(window_times)
        end

        # When window full, compute retrocausal estimate for oldest time
        if length(window_particles) == LAG + 1
            t_old = window_times[1]
            smoothed_mean = fixed_lag_smoother(window_particles, window_weights, window_times, Q)
            filtered_old = filtered_means[t_old]
            retro_old = α * filtered_old + β * smoothed_mean
            retro_means[t_old] = retro_old
        end
    end

    # MSE computation
    valid = .!isnan.(retro_means)
    mse_filter = mean((filtered_means[valid] .- x_true[valid]).^2)
    mse_retro = mean((retro_means[valid] .- x_true[valid]).^2)
    println("Filtering MSE (online): $(round(mse_filter, digits=4))")
    println("Retrocausal MSE (fixed lag $LAG): $(round(mse_retro, digits=4))")
    println("Improvement factor: $(round(mse_filter/mse_retro, digits=2))")

    # Plot
    p = plot(1:T, x_true, label="True state", linewidth=2, alpha=0.7, color=:black)
    plot!(p, 1:T, filtered_means, label="Filtered (online)", linestyle=:dash, color=:blue)
    plot!(p, 1:T, retro_means, label="Retrocausal (lag $LAG)", linewidth=2, color=:red)
    title!(p, "Fixed‑Lag Retrocausal Particle Smoother (Golden‑Ratio Weighted)")
    xlabel!(p, "Time step")
    ylabel!(p, "State")
    display(p)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

###########################################################
# Simple propagators
##

# Hamiltonian propagation
"""
    ham(dt::Float64, H::QOp; ket=false)

Return increment function for Hamiltonian evolution generated
by `H` over a time step `dt`.

Uses an exact matrix exponential, assuming no time-dependence.

### Returns:
  - ket=true  : ψ::QKet -> u * ψ
  - ket=false : ρ::QOp  -> u * ρ * u'

"""
function ham(dt::Float64, H::QOp; ket=false)
    const u::QOp = sparse(expm( -im * dt * full(H)))
    const ut = u'
    if ket
        ψ::QKet -> u * ψ
    else
        ρ::QOp -> u * ρ * ut
    end
end

# Jump-nojump Lindblad propagator
"""
    lind(dt::Float64, H::QOp, alist::QOp...)

Return increment function for Lindblad dissipative evolution generated
by Hamiltonian `H` and list of dissipative operators `alist` over a 
time step `dt`.

Uses the "jump no-jump" method to efficiently approximate the exact
Lindblad propagator as a composition of Hamiltonian evolution, jumps,
and no-jump informational backaction. Assumes no time-dependence,
and small dt.  [Physical Review A **92**, 052306 (2015)]

### Returns:
  - ρ(t)::QOp -> ρ(t+dt)

"""
@inline function lind(dt::Float64, H::QOp, alist::QOp...)
    h = ham(dt, H)
    const n::QOp = sparse(sqrtm(eye(H) - dt * full(mapreduce(a -> a' * a, +, alist))))
    no(ρ::QOp)::QOp = n * ρ * n
    dec(ρ::QOp)::QOp = mapreduce(a -> a * ρ * a', +, alist) * dt
    ρ::QOp -> let ρu = h(ρ); no(ρu) + dec(ρu) end
end

# Runge-Kutta Lindblad propagator
"""
    lind_runge(dt::Float64, H::QOp, alist::QOp...)

Return increment function for Lindblad dissipative evolution generated
by Hamiltonian `H` and list of dissipative operators `alist` over a 
time step `dt`.

Uses a 4th-order Runge-Kutta integration method to construct the state
increment from the first-order Lindblad differential (master) equation.

### Returns:
  - ρ(t)::QOp -> ρ(t) + dρ

"""
@inline function lind_runge(dt::Float64, H::QOp, alist::QOp...)
    inc(ρ::QOp)::QOp = - im * comm(H,ρ) * dt + sum(map(a -> diss(a)(ρ) * dt, alist))
    function rinc(ρ::QOp)::QOp
        dρ1::QOp = inc(ρ)
        dρ2::QOp = inc(ρ + dρ1 / 2)
        dρ3::QOp = inc(ρ + dρ2 / 2)
        dρ4::QOp = inc(ρ + dρ3)
        (dρ1 + 2*dρ2 + 2*dρ3 + dρ4)/6
    end
    ρ::QOp -> ρ + rinc(ρ)
end

###
# Crude trajectory integrator
###

# Return trajectory array [f1(now), f2(now), ...] for each increment dt up to tmax
"""
    trajectory(init::QOp, inc::Function, dt::Float64, 
               tmax::Float64, fs::Function...; points::Int=1000)

Compute time-stepped trajectory, starting from state `init`, incrementing with `inc`
by time step `dt` from `t=[0,tmax]`, keeping `points` intermediate values
of `f(ρ(t))` for each `f` in `fs`.

### Returns:
  - (ts::linspace, vals::[f(ρ(t))]...)

"""
function trajectory(init::QOp, inc::Function, dt::Float64, 
                    tmax::Float64, fs::Function...; points::Int=1000)
    # N steps, Nf stored values per step
    # Nl steps per point, Nldt: time-step per stored point
    const N = fld(tmax , dt)
    const Nf = length(fs)
    const Nl = fld(N,points)
    const Nldt = Nl*dt
    # Preallocate trajectory arrays for speed
    valtypes = collect(typeof(f(init)) for f in fs)
    traj = map(t->zeros(t, (points,1)), valtypes)
    ts = linspace(0.0::Float64, tmax, points)
    # Function to update values
    function update!(i::Int, ρ::QOp)
        for k in 1:Nf
            traj[k][i] = fs[k](ρ)
        end
    end
    # Seed loop
    info("Trajectory: steps = ",N,", points = ",points,", values = ",Nf)
    tic()
    now = init
    update!(1, now)
    # loop
    for i in 1:points
        # inner loop without storage
        for k in 1:Nl
            now = inc(now)
        end
        # store point
        update!(i, now)
    end
    elapsed = toq()
    # Performance summary
    info("Time elapsed: ",elapsed," s, Steps per second: ",N / elapsed)
    (ts, traj...)
end

using AMDGPU
using ExaTronKernels
using LinearAlgebra
using Random
using Test

try
    tmp = ROCArray{Float64}(undef, 10)
catch e
    throw(e)
end

"""
Test ExaTron's internal routines written for GPU.

The current implementation assumes the following:
  - A thread block takes a matrix structure, (tx,ty), with
    n <= blockDim().x = blockDim().y <= 32 and blockDim().x is even.
  - Arguments passed on to these routines are assumed to be
    of size at least n. This is to prevent multiple thread
    divergence when we call a function with n_hat < n.
    Such a case occurs when we fix active variables.

We test the following routines, where [O] indicates if the routine
is checked if n < blockDim().x is OK.
  - dicf     [O][O]: this routine also tests dnsol and dtsol.
  - dicfs    [O][T]
  - dcauchy  [O][T]
  - dtrpcg   [O][T]
  - dprsrch  [O][T]
  - daxpy    [O][O]
  - dssyax   [O][O]: we do shuffle using blockDim().x.
  - dmid     [O][O]: we could use a single thread only to multiple divergences.
  - dgpstep  [O][O]
  - dbreakpt [O][O]: we use the existing ExaTron implementation as is.
  - dnrm2    [O][O]: we do shuffle using blockDim().x.
  - nrm2     [O][O]: we do shuffle using blockDim().x.
  - dcopy    [O][O]
  - ddot     [O][O]
  - dscal    [O][O]
  - dtrqsol  [O][O]
  - dspcg    [O][T]: we use a single thread to avoid multiple divergences.
  - dgpnorm  [O][O]
  - dtron    [O]
  - driver_kernel
"""

Random.seed!(0)
itermax = 10
n = 4
nblk = 4

@testset "dicf" begin
    function dicf_test(
        ::Val{n},
        d_in::ROCDeviceArray{Float64},
        d_out::ROCDeviceArray{Float64}
        ) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        L = @amdlocalmem(Float64, n, n)
        for i in 1:n
            L[i,tx] = d_in[i,tx]
        end
        AMDGPU.sync_workgroup()

        # Test Cholesky factorization.
        ExaTronKernels.dicf(n,L)

        if bx == 1
            for i in 1:n
                d_out[i,tx] = L[i,tx]
            end
        end
        AMDGPU.sync_workgroup()
        return
    end

    for i=1:itermax
        L = tril(rand(n,n))
        A = L*transpose(L)
        A .= tril(A) .+ (transpose(tril(A)) .- Diagonal(A))
        tron_A = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)
        tron_A.vals .= A

        d_in = ROCArray{Float64,2}(undef, (n,n))
        d_out = ROCArray{Float64,2}(undef, (n,n))
        copyto!(d_in, tron_A.vals)
        wait(@roc groupsize=n gridsize=n*nblk dicf_test(Val(n),d_in,d_out))
        h_L = zeros(n,n)
        copyto!(h_L, d_out)

        tron_L = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)
        tron_L.vals .= tron_A.vals
        indr = zeros(Int, n)
        indf = zeros(n)
        list = zeros(n)
        w = zeros(n)
        ExaTronKernels.dicf(n, n^2, tron_L, 5, indr, indf, list, w)

        @test norm(tron_A.vals .- tril(h_L)*transpose(tril(h_L))) <= 1e-10
        @test norm(tril(h_L) .- transpose(triu(h_L))) <= 1e-10
        @test norm(tril(tron_L.vals) .- tril(h_L)) <= 1e-10
    end
end

@testset "dicfs" begin
    function dicfs_test(
        ::Val{n},
        alpha::Float64,
        dA::ROCDeviceArray{Float64},
        d_out::ROCDeviceArray{Float64}
        ) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        wa1 = @amdlocalmem(Float64, n)
        wa2 = @amdlocalmem(Float64, n)
        A = @amdlocalmem(Float64, n, n)
        L = @amdlocalmem(Float64, n, n)

        @inbounds for j=1:n
            A[j,tx] = dA[j,tx]
        end
        AMDGPU.sync_workgroup()

        ExaTronKernels.dicfs(n, alpha, A, L, wa1, wa2)
        if bx == 1
            @inbounds for j=1:n
                d_out[j,tx] = L[j,tx]
            end
        end
        AMDGPU.sync_workgroup()

        return
    end

    for i=1:itermax
        L = tril(rand(n,n))
        A = L*transpose(L)
        A .= tril(A) .+ (transpose(tril(A)) .- Diagonal(A))
        tron_A = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)
        tron_L = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)
        tron_A.vals .= A

        dA = ROCArray{Float64,2}(undef, (n,n))
        d_out = ROCArray{Float64,2}(undef, (n,n))
        alpha = 1.0
        copyto!(dA, tron_A.vals)
        wait(@roc groupsize=n gridsize=n*nblk dicfs_test(Val(n),alpha,dA,d_out))
        h_L = zeros(n,n)
        copyto!(h_L, d_out)
        iwa = zeros(Int, 3*n)
        wa1 = zeros(n)
        wa2 = zeros(n)
        ExaTronKernels.dicfs(n, n^2, tron_A, tron_L, 5, alpha, iwa, wa1, wa2)

        @test norm(tril(h_L) .- transpose(triu(h_L))) <= 1e-10
        @test norm(tril(tron_L.vals) .- tril(h_L)) <= 1e-9

        # Make it negative definite.
        for j=1:n
            tron_A.vals[j,j] = -tron_A.vals[j,j]
        end
        copyto!(dA, tron_A.vals)
        wait(@roc groupsize=n gridsize=n*nblk dicfs_test(Val(n),alpha,dA,d_out))
        copyto!(h_L, d_out)
        ExaTronKernels.dicfs(n, n^2, tron_A, tron_L, 5, alpha, iwa, wa1, wa2)

        @test norm(tril(h_L) .- transpose(triu(h_L))) <= 1e-10
        @test norm(tril(tron_L.vals) .- tril(h_L)) <= 1e-10
    end
end

@testset "dcauchy" begin
    function dcauchy_test(::Val{n},dx::ROCDeviceArray{Float64},
                            dl::ROCDeviceArray{Float64},
                            du::ROCDeviceArray{Float64},
                            dA::ROCDeviceArray{Float64},
                            dg::ROCDeviceArray{Float64},
                            delta::Float64,
                            alpha::Float64,
                            d_out1::ROCDeviceArray{Float64},
                            d_out2::ROCDeviceArray{Float64}) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        x =  @amdlocalmem(Float64, 4)
        xl = @amdlocalmem(Float64, 4) 
        xu = @amdlocalmem(Float64, 4) 
        g =  @amdlocalmem(Float64, 4) 
        s =  @amdlocalmem(Float64, 4) 
        wa = @amdlocalmem(Float64, 4) 
        A =  @amdlocalmem(Float64, 4, 4)

        for i in 1:n
            A[tx,i] = dA[tx,i]
        end
        x[tx] = dx[tx]
        xl[tx] = dl[tx]
        xu[tx] = du[tx]
        g[tx] = dg[tx]

        alpha = ExaTronKernels.dcauchy(n,x,xl,xu,A,g,delta,alpha,s,wa)
        if bx == 1
            d_out1[tx] = s[tx]
            d_out2[tx] = alpha
        end
        AMDGPU.sync_workgroup()

        return
    end

    for i=1:itermax
        L = tril(rand(n,n))
        A = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)
        A.vals .= L*transpose(L)
        A.vals .= tril(A.vals) .+ (transpose(tril(A.vals)) .- Diagonal(A.vals))
        x = rand(n)
        xl = x .- abs.(rand(n))
        xu = x .+ abs.(rand(n))
        g = A.vals*x .+ rand(n)
        s = zeros(n)
        wa = zeros(n)
        alpha = 1.0
        delta = 2.0*norm(g)

        dx = ROCArray{Float64}(undef, n)
        dl = ROCArray{Float64}(undef, n)
        du = ROCArray{Float64}(undef, n)
        dg = ROCArray{Float64}(undef, n)
        dA = ROCArray{Float64,2}(undef, (n,n))
        d_out1 = ROCArray{Float64}(undef, n)
        d_out2 = ROCArray{Float64}(undef, n)
        copyto!(dx, x)
        copyto!(dl, xl)
        copyto!(du, xu)
        copyto!(dg, g)
        copyto!(dA, A.vals)
        wait(@roc groupsize=n gridsize=n*nblk dcauchy_test(Val(n),dx,dl,du,dA,dg,delta,alpha,d_out1,d_out2))
        h_s = zeros(n)
        h_alpha = zeros(n)
        copyto!(h_s, d_out1)
        copyto!(h_alpha, d_out2)

        alpha = ExaTronKernels.dcauchy(n, x, xl, xu, A, g, delta, alpha, s, wa)

        @test norm(s .- h_s) <= 1e-10
        @test norm(alpha .- h_alpha) <= 1e-10
    end
end

@testset "dtrpcg" begin
    function dtrpcg_test(::Val{n}, delta::Float64, tol::Float64,
                            stol::Float64, d_in::ROCDeviceArray{Float64},
                            d_g::ROCDeviceArray{Float64},
                            d_out_L::ROCDeviceArray{Float64},
                            d_out::ROCDeviceArray{Float64}) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        A = @amdlocalmem(Float64, n, n)
        L = @amdlocalmem(Float64, n, n)

        g = @amdlocalmem(Float64, n)
        w = @amdlocalmem(Float64, n)
        p = @amdlocalmem(Float64, n)
        q = @amdlocalmem(Float64, n)
        r = @amdlocalmem(Float64, n)
        t = @amdlocalmem(Float64, n)
        z = @amdlocalmem(Float64, n)

        for i in 1:n
            A[i,tx] = d_in[i,tx]
            L[i,tx] = d_in[i,tx]
        end
        g[tx] = d_g[tx]
        AMDGPU.sync_workgroup()

        ExaTronKernels.dicf(n,L)
        info, iters = ExaTronKernels.dtrpcg(n,A,g,delta,L,tol,stol,n,w,p,q,r,t,z)
        if bx == 1
            d_out[tx] = w[tx]
            for i in 1:n
                d_out_L[i,tx] = L[i,tx]
            end
        end
        AMDGPU.sync_workgroup()

        return
    end

    delta = 100.0
    tol = 1e-6
    stol = 1e-6
    tron_A = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)
    tron_L = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)
    for i=1:itermax
        L = tril(rand(n,n))
        A = L*transpose(L)
        A .= tril(A) .+ (transpose(tril(A)) .- Diagonal(A))
        g = 0.1*ones(n)
        w = zeros(n)
        p = zeros(n)
        q = zeros(n)
        r = zeros(n)
        t = zeros(n)
        z = zeros(n)
        tron_A.vals .= A
        tron_L.vals .= A
        d_in = ROCArray{Float64,2}(undef, (n,n))
        d_g = ROCArray{Float64}(undef, n)
        d_out_L = ROCArray{Float64,2}(undef, (n,n))
        d_out = ROCArray{Float64}(undef, n)
        copyto!(d_in, A)
        copyto!(d_g, g)
        wait(@roc groupsize=n gridsize=n*nblk dtrpcg_test(Val(n),delta,tol,stol,d_in,d_g,d_out_L,d_out))
        h_w = zeros(n)
        h_L = zeros(n,n)
        copyto!(h_L, d_out_L)
        copyto!(h_w, d_out)

        indr = zeros(Int, n)
        indf = zeros(n)
        list = zeros(n)
        ExaTronKernels.dicf(n, n^2, tron_L, 5, indr, indf, list, w)
        ExaTronKernels.dtrpcg(n, tron_A, g, delta, tron_L, tol, stol, n, w, p, q, r, t, z)

        @test norm(tril(h_L) .- tril(tron_L.vals)) <= tol
        @test norm(h_w .- w) <= tol
    end
end

@testset "dprsrch" begin
    function dprsrch_test(::Val{n},d_x::ROCDeviceArray{Float64},
                            d_xl::ROCDeviceArray{Float64},
                            d_xu::ROCDeviceArray{Float64},
                            d_g::ROCDeviceArray{Float64},
                            d_w::ROCDeviceArray{Float64},
                            d_A::ROCDeviceArray{Float64},
                            d_out1::ROCDeviceArray{Float64},
                            d_out2::ROCDeviceArray{Float64}) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        x = @amdlocalmem(Float64, n)
        xl = @amdlocalmem(Float64, n)
        xu = @amdlocalmem(Float64, n)
        g = @amdlocalmem(Float64, n)
        w = @amdlocalmem(Float64, n)
        wa1 = @amdlocalmem(Float64, n)
        wa2 = @amdlocalmem(Float64, n)
        A = @amdlocalmem(Float64, n, n)
        for i in 1:n
            A[i,tx] = d_A[i,tx]
        end
        x[tx] = d_x[tx]
        xl[tx] = d_xl[tx]
        xu[tx] = d_xu[tx]
        g[tx] = d_g[tx]
        w[tx] = d_w[tx]
        AMDGPU.sync_workgroup()

        ExaTronKernels.dprsrch(n, x, xl, xu, A, g, w, wa1, wa2)
        if bx == 1
            d_out1[tx] = x[tx]
            d_out2[tx] = w[tx]
        end
        AMDGPU.sync_workgroup()

        return
    end

    for i=1:itermax
        L = tril(rand(n,n))
        A = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)
        A.vals .= L*transpose(L)
        A.vals .= tril(A.vals) .+ (transpose(tril(A.vals)) .- Diagonal(A.vals))
        x = rand(n)
        xl = x .- abs.(rand(n))
        xu = x .+ abs.(rand(n))
        g = A.vals*x .+ rand(n)
        w = -g
        wa1 = zeros(n)
        wa2 = zeros(n)

        dx = ROCArray{Float64}(undef, n)
        dl = ROCArray{Float64}(undef, n)
        du = ROCArray{Float64}(undef, n)
        dg = ROCArray{Float64}(undef, n)
        dw = ROCArray{Float64}(undef, n)
        dA = ROCArray{Float64,2}(undef, (n,n))
        d_out1 = ROCArray{Float64}(undef, n)
        d_out2 = ROCArray{Float64}(undef, n)
        copyto!(dx, x)
        copyto!(dl, xl)
        copyto!(du, xu)
        copyto!(dg, g)
        copyto!(dw, w)
        copyto!(dA, A.vals)
        wait(@roc groupsize=n gridsize=n*nblk dprsrch_test(Val(n),dx,dl,du,dg,dw,dA,d_out1,d_out2))
        h_x = zeros(n)
        h_w = zeros(n)
        copyto!(h_x, d_out1)
        copyto!(h_w, d_out2)

        ExaTronKernels.dprsrch(n,x,xl,xu,A,g,w,wa1,wa2)

        @test norm(x .- h_x) <= 1e-10
        @test norm(w .- h_w) <= 1e-10
    end
end

@testset "daxpy" begin
    function daxpy_test(::Val{n}, da, d_in::ROCDeviceArray{Float64},
                        d_out::ROCDeviceArray{Float64}) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        x = @amdlocalmem(Float64, n)
        y = @amdlocalmem(Float64, n)
        x[tx] = d_in[tx]
        y[tx] = d_in[tx + n]
        AMDGPU.sync_workgroup()

        ExaTronKernels.daxpy(n, da, x, 1, y, 1)
        if bx == 1
            d_out[tx] = y[tx]
        end
        AMDGPU.sync_workgroup()

        return
    end

    for i=1:itermax
        da = rand(1)[1]
        h_in = rand(2*n)
        h_out = zeros(n)
        d_in = ROCArray{Float64}(undef, 2*n)
        d_out = ROCArray{Float64}(undef, n)
        copyto!(d_in, h_in)
        wait(@roc groupsize=n gridsize=n*nblk daxpy_test(Val(n),da,d_in,d_out))
        copyto!(h_out, d_out)

        @test norm(h_out .- (h_in[n+1:2*n] .+ da.*h_in[1:n])) <= 1e-12
    end
end

@testset "dssyax" begin
    function dssyax_test(::Val{n},d_z::ROCDeviceArray{Float64},
                            d_in::ROCDeviceArray{Float64},
                            d_out::ROCDeviceArray{Float64}) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        z = @amdlocalmem(Float64, n)
        q = @amdlocalmem(Float64, n)
        A = @amdlocalmem(Float64, n, n)
        for i in 1:n
            A[i,tx] = d_in[i,tx]
        end
        z[tx] = d_z[tx]
        AMDGPU.sync_workgroup()

        ExaTronKernels.dssyax(n, A, z, q)
        if bx == 1
            d_out[tx] = q[tx]
        end
        AMDGPU.sync_workgroup()

        return
    end

    for i=1:itermax
        z = rand(n)
        h_in = rand(n,n)
        h_out = zeros(n)
        d_z = ROCArray{Float64}(undef, n)
        d_in = ROCArray{Float64,2}(undef, (n,n))
        d_out = ROCArray{Float64}(undef, n)
        copyto!(d_z, z)
        copyto!(d_in, h_in)
        wait(@roc groupsize=n gridsize=n*nblk dssyax_test(Val(n),d_z,d_in,d_out))
        copyto!(h_out, d_out)
        @test norm(h_out .- h_in*z) <= 1e-12
    end
end

@testset "dmid" begin
    function dmid_test(::Val{n}, dx::ROCDeviceArray{Float64},
                        dl::ROCDeviceArray{Float64},
                        du::ROCDeviceArray{Float64},
                        d_out::ROCDeviceArray{Float64}) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        x = @amdlocalmem(Float64, n)
        xl = @amdlocalmem(Float64, n)
        xu = @amdlocalmem(Float64, n)
        x[tx] = dx[tx]
        xl[tx] = dl[tx]
        xu[tx] = du[tx]
        AMDGPU.sync_workgroup()

        ExaTronKernels.dmid(n, x, xl, xu)
        if bx == 1
            d_out[tx] = x[tx]
        end
        AMDGPU.sync_workgroup()

        return
    end

    for i=1:itermax
        x = rand(n)
        xl = x .- abs.(rand(n))
        xu = x .+ abs.(rand(n))

        # Force some components to go below or above bounds
        # so that we can test all cases.
        for j=1:n
            k = rand(1:3)
            if k == 1
                x[j] = xl[j] - 0.1
            elseif k == 2
                x[j] = xu[j] + 0.1
            end
        end
        x_out = zeros(n)
        dx = ROCArray{Float64}(undef, n)
        dl = ROCArray{Float64}(undef, n)
        du = ROCArray{Float64}(undef, n)
        d_out = ROCArray{Float64}(undef, n)
        copyto!(dx, x)
        copyto!(dl, xl)
        copyto!(du, xu)
        wait(@roc groupsize=n gridsize=n*nblk dmid_test(Val(n),dx,dl,du,d_out))
        copyto!(x_out, d_out)

        ExaTronKernels.dmid(n, x, xl, xu)
        @test !(false in (x .== x_out))
    end
end

@testset "dgpstep" begin
    function dgpstep_test(::Val{n},dx::ROCDeviceArray{Float64},
                            dl::ROCDeviceArray{Float64},
                            du::ROCDeviceArray{Float64},
                            alpha::Float64,
                            dw::ROCDeviceArray{Float64},
                            d_out::ROCDeviceArray{Float64}) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        x = @amdlocalmem(Float64, n)
        xl = @amdlocalmem(Float64, n)
        xu = @amdlocalmem(Float64, n)
        w = @amdlocalmem(Float64, n)
        s = @amdlocalmem(Float64, n)
        x[tx] = dx[tx]
        xl[tx] = dl[tx]
        xu[tx] = du[tx]
        w[tx] = dw[tx]
        AMDGPU.sync_workgroup()

        ExaTronKernels.dgpstep(n, x, xl, xu, alpha, w, s)
        if bx == 1
            d_out[tx] = s[tx]
        end
        AMDGPU.sync_workgroup()

        return
    end

    for i=1:itermax
        x = rand(n)
        xl = x .- abs.(rand(n))
        xu = x .+ abs.(rand(n))
        w = rand(n)
        alpha = rand(1)[1]
        s = zeros(n)
        s_out = zeros(n)

        # Force some components to go below or above bounds
        # so that we can test all cases.
        for j=1:n
            k = rand(1:3)
            if k == 1
                if x[j] + alpha*w[j] >= xl[j]
                    w[j] = (xl[j] - x[j]) / alpha - 0.1
                end
            elseif k == 2
                if x[j] + alpha*w[j] <= xu[j]
                    w[j] = (xu[j] - x[j]) / alpha + 0.1
                end
            end
        end

        dx = ROCArray{Float64}(undef, n)
        dl = ROCArray{Float64}(undef, n)
        du = ROCArray{Float64}(undef, n)
        dw = ROCArray{Float64}(undef, n)
        d_out = ROCArray{Float64}(undef, n)
        copyto!(dx, x)
        copyto!(dl, xl)
        copyto!(du, xu)
        copyto!(dw, w)
        wait(@roc groupsize=n gridsize=n*nblk dgpstep_test(Val(n),dx,dl,du,alpha,dw,d_out))
        copyto!(s_out, d_out)

        ExaTronKernels.dgpstep(n, x, xl, xu, alpha, w, s)
        @test !(false in (s .== s_out))
    end
end

@testset "dbreakpt" begin
    function dbreakpt_test(::Val{n},dx::ROCDeviceArray{Float64},
                            dl::ROCDeviceArray{Float64},
                            du::ROCDeviceArray{Float64},
                            dw::ROCDeviceArray{Float64},
                            d_nbrpt::ROCDeviceArray{Float64},
                            d_brptmin::ROCDeviceArray{Float64},
                            d_brptmax::ROCDeviceArray{Float64}) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        x = @amdlocalmem(Float64, n)
        xl = @amdlocalmem(Float64, n)
        xu = @amdlocalmem(Float64, n)
        w = @amdlocalmem(Float64, n)
        x[tx] = dx[tx]
        xl[tx] = dl[tx]
        xu[tx] = du[tx]
        w[tx] = dw[tx]
        AMDGPU.sync_workgroup()

        nbrpt, brptmin, brptmax = ExaTronKernels.dbreakpt(n, x, xl, xu, w)
        for i in 1:n
            d_nbrpt[i,tx] = nbrpt
            d_brptmin[i,tx] = brptmin
            d_brptmax[i,tx] = brptmax
        end
        AMDGPU.sync_workgroup()

        return
    end

    for i=1:itermax
        x = rand(n)
        xl = x .- abs.(rand(n))
        xu = x .+ abs.(rand(n))
        w = 2.0*rand(n) .- 1.0     # (-1,1]
        h_nbrpt = zeros((n,n))
        h_brptmin = zeros((n,n))
        h_brptmax = zeros((n,n))

        dx = ROCArray{Float64}(undef, n)
        dl = ROCArray{Float64}(undef, n)
        du = ROCArray{Float64}(undef, n)
        dw = ROCArray{Float64}(undef, n)
        d_nbrpt = ROCArray{Float64,2}(undef, (n,n))
        d_brptmin = ROCArray{Float64,2}(undef, (n,n))
        d_brptmax = ROCArray{Float64,2}(undef, (n,n))
        copyto!(dx, x)
        copyto!(dl, xl)
        copyto!(du, xu)
        copyto!(dw, w)
        wait(@roc groupsize=n gridsize=n*nblk dbreakpt_test(Val(n),dx,dl,du,dw,d_nbrpt,d_brptmin,d_brptmax))
        copyto!(h_nbrpt, d_nbrpt)
        copyto!(h_brptmin, d_brptmin)
        copyto!(h_brptmax, d_brptmax)

        nbrpt, brptmin, brptmax = ExaTronKernels.dbreakpt(n, x, xl, xu, w)
        @test !(false in (nbrpt .== h_nbrpt))
        @test !(false in (brptmin .== h_brptmin))
        @test !(false in (brptmax .== h_brptmax))
    end
end

@testset "dnrm2" begin
    function dnrm2_test(
        ::Val{n},
        d_in::ROCDeviceArray{Float64},
        d_out::ROCDeviceArray{Float64}
        ) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        x = @amdlocalmem(Float64, n)
        x[tx] = d_in[tx]
        AMDGPU.sync_workgroup()

        v = ExaTronKernels.dnrm2(n, x, 1)
        if bx == 1
            d_out[tx] = v
        end
        AMDGPU.sync_workgroup()

        return
    end

    @inbounds for i=1:itermax
        h_in = rand(n)
        h_out = zeros(n)
        d_in = ROCArray{Float64}(undef, n)
        d_out = ROCArray{Float64}(undef, n)
        copyto!(d_in, h_in)
        wait(@roc groupsize=n gridsize=n*nblk dnrm2_test(Val(n),d_in,d_out))
        copyto!(h_out, d_out)
        xnorm = norm(h_in, 2)

        @test norm(xnorm .- h_out) <= 1e-10
    end
end

@testset "nrm2" begin
    function nrm2_test(
        ::Val{n},
        d_A::ROCDeviceArray{Float64},
        d_out::ROCDeviceArray{Float64}
        ) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        wa = @amdlocalmem(Float64, n)
        A = @amdlocalmem(Float64, n, n)

        for i in 1:n
            A[i,tx] = d_A[i,tx]
        end
        AMDGPU.sync_workgroup()

        ExaTronKernels.nrm2!(wa, A, n)
        if bx == 1
            d_out[tx] = wa[tx]
        end
        AMDGPU.sync_workgroup()

        return
    end

    @inbounds for i=1:itermax
        L = tril(rand(n,n))
        A = L*transpose(L)
        A .= tril(A) .+ (transpose(tril(A)) .- Diagonal(A))
        wa = zeros(n)
        tron_A = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)
        tron_A.vals .= A
        ExaTronKernels.nrm2!(wa, tron_A, n)

        d_A = ROCArray{Float64,2}(undef, (n,n))
        d_out = ROCArray{Float64}(undef, n)
        h_wa = zeros(n)
        copyto!(d_A, A)
        wait(@roc groupsize=n gridsize=n*nblk nrm2_test(Val(n),d_A,d_out))
        copyto!(h_wa, d_out)

        @test norm(wa .- h_wa) <= 1e-10
    end
end

@testset "dcopy" begin
    function dcopy_test(::Val{n}, d_in::ROCDeviceArray{Float64},
                        d_out::ROCDeviceArray{Float64}) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        x = @amdlocalmem(Float64, n)
        y = @amdlocalmem(Float64, n)

        x[tx] = d_in[tx]
        AMDGPU.sync_workgroup()

        ExaTronKernels.dcopy(n, x, 1, y, 1)

        if bx == 1
            d_out[tx] = y[tx]
        end
        AMDGPU.sync_workgroup()

        return
    end

    @inbounds for i=1:itermax
        h_in = rand(n)
        h_out = zeros(n)
        d_in = ROCArray{Float64}(undef, n)
        d_out = ROCArray{Float64}(undef, n)
        copyto!(d_in, h_in)
        wait(@roc groupsize=n gridsize=n*nblk dcopy_test(Val(n),d_in,d_out))
        copyto!(h_out, d_out)

        @test !(false in (h_in .== h_out))
    end
end

@testset "ddot" begin
    function ddot_test(::Val{n}, d_in::ROCDeviceArray{Float64},
                        d_out::ROCDeviceArray{Float64}) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        x = @amdlocalmem(Float64, n) 
        y = @amdlocalmem(Float64, n) 
        x[tx] = d_in[tx]
        y[tx] = d_in[tx]
        AMDGPU.sync_workgroup()

        v = ExaTronKernels.ddot(n, x, 1, y, 1)
        if bx == 1
            for i in 1:n
                d_out[i,tx] = v
            end
        end
        AMDGPU.sync_workgroup()

        return
    end

    @inbounds for i=1:itermax
        h_in = rand(n)
        h_out = zeros((n,n))
        d_in = ROCArray{Float64}(undef, n)
        d_out = ROCArray{Float64,2}(undef, (n,n))
        copyto!(d_in, h_in)
        wait(@roc groupsize=n gridsize=n*nblk ddot_test(Val(n),d_in,d_out))
        copyto!(h_out, d_out)

        @test norm(dot(h_in,h_in) .- h_out, 2) <= 1e-10
    end
end

@testset "dscal" begin
    function dscal_test(::Val{n}, da::Float64,
                        d_in::ROCDeviceArray{Float64},
                        d_out::ROCDeviceArray{Float64}) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        x = @amdlocalmem(Float64, n)
        x[tx] = d_in[tx]
        AMDGPU.sync_workgroup()

        ExaTronKernels.dscal(n, da, x, 1)
        if bx == 1
            d_out[tx] = x[tx]
        end
        AMDGPU.sync_workgroup()

        return
    end

    for i=1:itermax
        h_in = rand(n)
        h_out = zeros(n)
        da = rand(1)[1]
        d_in = ROCArray{Float64}(undef, n)
        d_out = ROCArray{Float64}(undef, n)
        copyto!(d_in, h_in)
        wait(@roc groupsize=n gridsize=n*nblk dscal_test(Val(n),da,d_in,d_out))
        copyto!(h_out, d_out)

        @test norm(h_out .- (da.*h_in)) <= 1e-12
    end
end

@testset "dtrqsol" begin
    function dtrqsol_test(::Val{n}, d_x::ROCDeviceArray{Float64},
                            d_p::ROCDeviceArray{Float64},
                            d_out::ROCDeviceArray{Float64},
                            delta::Float64) where {n}
        tx = workitemIdx().x
        bx = workitemIdx().y

        x = @amdlocalmem(Float64, n)
        p = @amdlocalmem(Float64, n)

        x[tx] = d_x[tx]
        p[tx] = d_p[tx]
        AMDGPU.sync_workgroup()

        sigma = ExaTronKernels.dtrqsol(n, x, p, delta)
        if bx == 1
            for i in 1:n
                d_out[i,tx] = sigma
            end
        end
        AMDGPU.sync_workgroup()
    end

    for i=1:itermax
        x = rand(n)
        p = rand(n)
        sigma = abs(rand(1)[1])
        delta = norm(x .+ sigma.*p)

        d_x = ROCArray{Float64}(undef, n)
        d_p = ROCArray{Float64}(undef, n)
        d_out = ROCArray{Float64,2}(undef, (n,n))
        copyto!(d_x, x)
        copyto!(d_p, p)
        wait(@roc groupsize=n gridsize=n*nblk dtrqsol_test(Val(n),d_x,d_p,d_out,delta))

        @test norm(sigma .- d_out) <= 1e-10
    end
end

@testset "dspcg" begin
    function dspcg_test(::Val{n}, delta::Float64, rtol::Float64,
                        cg_itermax::Int, dx::ROCDeviceArray{Float64},
                        dxl::ROCDeviceArray{Float64},
                        dxu::ROCDeviceArray{Float64},
                        dA::ROCDeviceArray{Float64},
                        dg::ROCDeviceArray{Float64},
                        ds::ROCDeviceArray{Float64},
                        d_out::ROCDeviceArray{Float64}) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        x = @amdlocalmem(Float64, n)
        xl = @amdlocalmem(Float64, n)
        xu = @amdlocalmem(Float64, n)
        g = @amdlocalmem(Float64, n)
        s = @amdlocalmem(Float64, n)
        w = @amdlocalmem(Float64, n)
        wa1 = @amdlocalmem(Float64, n)
        wa2 = @amdlocalmem(Float64, n)
        wa3 = @amdlocalmem(Float64, n)
        wa4 = @amdlocalmem(Float64, n)
        wa5 = @amdlocalmem(Float64, n)
        gfree = @amdlocalmem(Float64, n)
        indfree = @amdlocalmem(Int, n)
        iwa = @amdlocalmem(Int, 2*n) 

        A = @amdlocalmem(Float64, n, n)
        B = @amdlocalmem(Float64, n, n)
        L = @amdlocalmem(Float64, n, n)

        @inbounds for j=1:n
            A[j,tx] = dA[j,tx]
        end
        x[tx] = dx[tx]
        xl[tx] = dxl[tx]
        xu[tx] = dxu[tx]
        g[tx] = dg[tx]
        s[tx] = ds[tx]
        AMDGPU.sync_workgroup()

        ExaTronKernels.dspcg(n, delta, rtol, cg_itermax, x, xl, xu,
                        A, g, s, B, L, indfree, gfree, w, iwa,
                        wa1, wa2, wa3, wa4, wa5)

        if bx == 1
            d_out[tx] = x[tx]
        end
        AMDGPU.sync_workgroup()

        return
    end

    for i=1:itermax
        L = tril(rand(n,n))
        A = L*transpose(L)
        A .= tril(A) .+ (transpose(tril(A)) .- Diagonal(A))
        tron_A = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)
        tron_A.vals .= A
        tron_B = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)
        tron_L = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)
        x = rand(n)
        xl = x .- abs.(rand(n))
        xu = x .+ abs.(rand(n))
        g = A*x .+ rand(n)
        s = rand(n)
        delta = 2.0*norm(g)
        rtol = 1e-6
        cg_itermax = n
        w = zeros(n)
        wa = zeros(5*n)
        gfree = zeros(n)
        indfree = zeros(Int, n)
        iwa = zeros(Int, 3*n)

        dx = ROCArray{Float64}(undef, n)
        dxl = ROCArray{Float64}(undef, n)
        dxu = ROCArray{Float64}(undef, n)
        dA = ROCArray{Float64,2}(undef, (n,n))
        dg = ROCArray{Float64}(undef, n)
        ds = ROCArray{Float64}(undef, n)
        d_out = ROCArray{Float64}(undef, n)

        copyto!(dx, x)
        copyto!(dxl, xl)
        copyto!(dxu, xu)
        copyto!(dA, tron_A.vals)
        copyto!(dg, g)
        copyto!(ds, s)

        wait(@roc groupsize=n gridsize=n*nblk dspcg_test(Val(n),delta,rtol,cg_itermax,dx,dxl,dxu,dA,dg,ds,d_out))
        h_x = zeros(n)
        copyto!(h_x, d_out)

        ExaTronKernels.dspcg(n, x, xl, xu, tron_A, g, delta, rtol, s, 5, cg_itermax,
                        tron_B, tron_L, indfree, gfree, w, wa, iwa)

        @test norm(x .- h_x) <= 1e-10
    end
end

@testset "dgpnorm" begin
    function dgpnorm_test(::Val{n}, dx, dxl, dxu, dg, d_out) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        x = @amdlocalmem(Float64, n)
        xl = @amdlocalmem(Float64, n)
        xu = @amdlocalmem(Float64, n)
        g = @amdlocalmem(Float64, n)

        x[tx] = dx[tx]
        xl[tx] = dxl[tx]
        xu[tx] = dxu[tx]
        g[tx] = dg[tx]
        AMDGPU.sync_workgroup()

        v = ExaTronKernels.dgpnorm(n, x, xl, xu, g)
        # v = 0.0
        if bx == 1
            d_out[tx] = v
        end
        AMDGPU.sync_workgroup()

        return
    end

    for i=1:itermax
        x = rand(n)
        xl = x .- abs.(rand(n))
        xu = x .+ abs.(rand(n))
        g = 2.0*rand(n) .- 1.0

        dx = ROCArray{Float64}(undef, n)
        dxl = ROCArray{Float64}(undef, n)
        dxu = ROCArray{Float64}(undef, n)
        dg = ROCArray{Float64}(undef, n)
        d_out = ROCArray{Float64}(undef, n)

        copyto!(dx, x)
        copyto!(dxl, xl)
        copyto!(dxu, xu)
        copyto!(dg, g)

        gptime = @timed wait(@roc groupsize=n gridsize=n*nblk dgpnorm_test(Val(n), dx, dxl, dxu, dg, d_out))
        h_v = zeros(n)
        copyto!(h_v, d_out)

        v = ExaTronKernels.dgpnorm(n, x, xl, xu, g)
        @test norm(h_v .- v) <= 1e-10
    end
end

@testset "dtron" begin
    function dtron_test(::Val{n}, f::Float64, frtol::Float64, fatol::Float64, fmin::Float64,
                        cgtol::Float64, cg_itermax::Int, delta::Float64, task::Int,
                        disave::ROCDeviceArray{Int}, ddsave::ROCDeviceArray{Float64},
                        dx::ROCDeviceArray{Float64}, dxl::ROCDeviceArray{Float64},
                        dxu::ROCDeviceArray{Float64}, dA::ROCDeviceArray{Float64},
                        dg::ROCDeviceArray{Float64}, d_out::ROCDeviceArray{Float64}) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        x = @amdlocalmem(Float64, n)
        xl = @amdlocalmem(Float64, n)
        xu = @amdlocalmem(Float64, n)
        g = @amdlocalmem(Float64, n)
        xc = @amdlocalmem(Float64, n)
        s = @amdlocalmem(Float64, n)
        wa = @amdlocalmem(Float64, n)
        wa1 = @amdlocalmem(Float64, n)
        wa2 = @amdlocalmem(Float64, n)
        wa3 = @amdlocalmem(Float64, n)
        wa4 = @amdlocalmem(Float64, n)
        wa5 = @amdlocalmem(Float64, n)
        gfree = @amdlocalmem(Float64, n)
        indfree = @amdlocalmem(Int, n)
        iwa = @amdlocalmem(Int, 2*n)

        A = @amdlocalmem(Float64, n, n)
        B = @amdlocalmem(Float64, n, n)
        L = @amdlocalmem(Float64, n, n)

        @inbounds for j=1:n
            A[j,tx] = dA[j,tx]
        end
        x[tx] = dx[tx]
        xl[tx] = dxl[tx]
        xu[tx] = dxu[tx]
        g[tx] = dg[tx]
        AMDGPU.sync_workgroup()

        ExaTronKernels.dtron(n, x, xl, xu, f, g, A, frtol, fatol, fmin, cgtol,
                        cg_itermax, delta, task, B, L, xc, s, indfree, gfree,
                        disave, ddsave, wa, iwa, wa1, wa2, wa3, wa4, wa5)

        if bx == 1
            d_out[tx] = x[tx]
        end
        AMDGPU.sync_workgroup()

        return
    end

    for i=1:itermax
        L = tril(rand(n,n))
        A = L*transpose(L)
        A .= tril(A) .+ (transpose(tril(A)) .- Diagonal(A))
        x = rand(n)
        xl = x .- abs.(rand(n))
        xu = x .+ abs.(rand(n))
        c = rand(n)
        g = A*x .+ c
        xc = zeros(n)
        s = zeros(n)
        wa = zeros(7*n)
        gfree = zeros(n)
        indfree = zeros(Int, n)
        iwa = zeros(Int, 3*n)
        isave = zeros(Int, 3)
        dsave = zeros(3)
        task = 0
        fatol = 0.0
        frtol = 1e-12
        fmin = -1e32
        cgtol = 0.1
        cg_itermax = n
        delta = 2.0*norm(g)
        f = 0.5*transpose(x)*A*x .+ transpose(x)*c

        tron_A = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)
        tron_A.vals .= A
        tron_B = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)
        tron_L = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)

        dx = ROCArray{Float64}(undef, n)
        dxl = ROCArray{Float64}(undef, n)
        dxu = ROCArray{Float64}(undef, n)
        dA = ROCArray{Float64,2}(undef, (n,n))
        dg = ROCArray{Float64}(undef, n)
        disave = ROCArray{Int}(undef, n)
        ddsave = ROCArray{Float64}(undef, n)
        d_out = ROCArray{Float64}(undef, n)

        copyto!(dx, x)
        copyto!(dxl, xl)
        copyto!(dxu, xu)
        copyto!(dA, tron_A.vals)
        copyto!(dg, g)

        wait(@roc groupsize=n gridsize=n*nblk dtron_test(Val(n),f,frtol,fatol,fmin,cgtol,cg_itermax,delta,task,disave,ddsave,dx,dxl,dxu,dA,dg,d_out))
        h_x = zeros(n)
        copyto!(h_x, d_out)

        task_str = Vector{UInt8}(undef, 60)
        for (i,s) in enumerate("START")
            task_str[i] = UInt8(s)
        end

        ExaTronKernels.dtron(n, x, xl, xu, f, g, tron_A, frtol, fatol, fmin, cgtol,
                        cg_itermax, delta, task_str, tron_B, tron_L, xc, s, indfree,
                        isave, dsave, wa, iwa)
        @test norm(x .- h_x) <= 1e-10
    end
end

@testset "driver_kernel" begin
    @inline function eval_f(n, x, dA, dc)
        f = 0
        @inbounds for i=1:n
            @inbounds for j=1:n
                f += x[i]*dA[i,j]*x[j]
            end
        end
        f = 0.5*f
        @inbounds for i=1:n
            f += x[i]*dc[i]
        end
        AMDGPU.sync_workgroup()
        return f
    end

    @inline function eval_g(n, x, g, dA, dc)
        @inbounds for i=1:n
            gval = 0
            @inbounds for j=1:n
                gval += dA[i,j]*x[j]
            end
            g[i] = gval + dc[i]
        end
        AMDGPU.sync_workgroup()
        return
    end

    @inline function eval_h(n, scale, x, A, dA)
        tx = workitemIdx().x

        @inbounds for j=1:n
            A[j,tx] = dA[j,tx]
        end
        AMDGPU.sync_workgroup()
        return
    end

    @inline function driver_kernel(N::Val{n}, max_feval::Int, max_minor::Int,
                            x::ROCDeviceArray{Float64}, xl::ROCDeviceArray{Float64},
                            xu::ROCDeviceArray{Float64}, dA::ROCDeviceArray{Float64,2},
                            dc::ROCDeviceArray{Float64}) where {n}
        # We start with a shared memory allocation.
        # The first 3*n*sizeof(Float64) bytes are used for x, xl, and xu.

        g = @amdlocalmem(Float64, n)
        xc = @amdlocalmem(Float64, n)
        s = @amdlocalmem(Float64, n)
        wa = @amdlocalmem(Float64, n)
        wa1 = @amdlocalmem(Float64, n)
        wa2 = @amdlocalmem(Float64, n)
        wa3 = @amdlocalmem(Float64, n)
        wa4 = @amdlocalmem(Float64, n)
        wa5 = @amdlocalmem(Float64, n)
        gfree = @amdlocalmem(Float64, n)
        dsave = @amdlocalmem(Float64, n)
        indfree = @amdlocalmem(Int, n)
        iwa = @amdlocalmem(Int, 2*n)
        isave = @amdlocalmem(Int, n)

        A = @amdlocalmem(Float64, n, n)
        B = @amdlocalmem(Float64, n, n)
        L = @amdlocalmem(Float64, n, n)

        task = 0
        status = 0

        delta = 0.0
        fatol = 0.0
        frtol = 1e-12
        fmin = -1e32
        gtol = 1e-6
        cgtol = 0.1
        cg_itermax = n

        f = 0.0
        nfev = 0
        ngev = 0
        nhev = 0
        minor_iter = 0
        search = true

        while search

            # [0|1]: Evaluate function.

            if task == 0 || task == 1
                f = eval_f(n, x, dA, dc)
                nfev += 1
                if nfev >= max_feval
                    search = false
                end
            end

            # [2] G or H: Evaluate gradient and Hessian.

            if task == 0 || task == 2
                eval_g(n, x, g, dA, dc)
                eval_h(n, 1.0, x, A, dA)
                ngev += 1
                nhev += 1
                minor_iter += 1
            end

            # Initialize the trust region bound.

            if task == 0
                gnorm0 = ExaTronKernels.dnrm2(n, g, 1)
                delta = gnorm0
            end

            # Call Tron.

            if search
                delta, task = ExaTronKernels.dtron(n, x, xl, xu, f, g, A, frtol, fatol, fmin, cgtol,
                                            cg_itermax, delta, task, B, L, xc, s, indfree, gfree,
                                            isave, dsave, wa, iwa, wa1, wa2, wa3, wa4, wa5)
            end

            # [3] NEWX: a new point was computed.

            if task == 3
                gnorm_inf = ExaTronKernels.dgpnorm(n, x, xl, xu, g)
                if gnorm_inf <= gtol
                    task = 4
                end

                if minor_iter >= max_minor
                    status = 1
                    search = false
                end
            end

            # [4] CONV: convergence was achieved.

            if task == 4
                search = false
            end
        end

        return status, minor_iter
    end

    function driver_kernel_test(N::Val{n}, max_feval, max_minor,
                                dx, dxl, dxu, dA, dc, d_out) where {n}
        tx = workitemIdx().x
        bx = workgroupIdx().x

        x = @amdlocalmem(Float64, n)
        xl = @amdlocalmem(Float64, n)
        xu = @amdlocalmem(Float64, n)

        x[tx] = dx[tx]
        xl[tx] = dxl[tx]
        xu[tx] = dxu[tx]
        AMDGPU.sync_workgroup()

        status, minor_iter = driver_kernel(N, max_feval, max_minor, x, xl, xu, dA, dc)

        if bx == 1
            d_out[tx] = x[tx]
        end
        AMDGPU.sync_workgroup()
        return
    end

    max_feval = 500
    max_minor = 100

    tron_A = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)
    tron_B = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)
    tron_L = ExaTronKernels.TronDenseMatrix{Array{Float64,2}}(n)

    dx = ROCArray{Float64}(undef, n)
    dxl = ROCArray{Float64}(undef, n)
    dxu = ROCArray{Float64}(undef, n)
    dA = ROCArray{Float64,2}(undef, (n,n))
    dc = ROCArray{Float64}(undef, n)
    d_out = ROCArray{Float64}(undef, n)

    for i=1:itermax
        L = tril(rand(n,n))
        A = L*transpose(L)
        A .= tril(A) .+ (transpose(tril(A)) .- Diagonal(A))
        x = rand(n)
        xl = x .- abs.(rand(n))
        xu = x .+ abs.(rand(n))
        c = rand(n)

        tron_A.vals .= A

        copyto!(dx, x)
        copyto!(dxl, xl)
        copyto!(dxu, xu)
        copyto!(dA, tron_A.vals)
        copyto!(dc, c)

        function eval_f_cb(x)
            f = 0.5*(transpose(x)*A*x) + transpose(c)*x
            return f
        end

        function eval_g_cb(x, g)
            g .= A*x .+ c
        end

        function eval_h_cb(x, mode, rows, cols, scale, lambda, values)
            nz = 1
            if mode == :Structure
                @inbounds for j=1:n
                    @inbounds for i=j:n
                        rows[nz] = i
                        cols[nz] = j
                        nz += 1
                    end
                end
            else
                @inbounds for j=1:n
                    @inbounds for i=j:n
                        values[nz] = A[i,j]
                        nz += 1
                    end
                end
            end
        end

        nele_hess = div(n*(n+1), 2)
        tron = ExaTronKernels.createProblem(n, xl, xu, nele_hess, eval_f_cb, eval_g_cb, eval_h_cb; :matrix_type=>:Dense, :max_minor=>max_minor)
        copyto!(tron.x, x)
        status = ExaTronKernels.solveProblem(tron)
        wait(@roc groupsize=n gridsize=n*nblk driver_kernel_test(Val(n),max_feval,max_minor,dx,dxl,dxu,dA,dc,d_out))
        h_x = zeros(n)
        copyto!(h_x, d_out)

        @test norm(h_x .- tron.x) <= 1e-10
    end
end

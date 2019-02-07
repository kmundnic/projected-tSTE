@def check_tste_params begin
    if !haskey(params, :α)
        throw(ArgumentError("params has no key :α"))
    elseif params[:α] <= 1
        throw(ArgumentError("Parameter α must be > 1"))
    end

    if !haskey(params, :λ)
        throw(ArgumentError("params has no key :λ"))
    elseif params[:λ] < 0
        throw(ArgumentError("Regularizer λ must be >= 0"))
    end
end

struct tSTE <: TripletEmbedding
    @add_embedding_fields

    function tSTE(
        triplets::Array{Int64,2},
        dimensions::Int64,
        params::Dict{Symbol,Real},
        X::Embedding)
        
        no_triplets::Int64 = size(triplets,1)
        no_items::Int64 = maximum(triplets)

        @check_embedding_conditions
        @check_tste_params
        
        new(triplets, dimensions, params, X, no_triplets, no_items)
    end

    """
    Constructor that initializes with a random (normal)
    embedding.
    """
    function tSTE(
        triplets::Array{Int64,2},
        dimensions::Int64,
        params::Dict{Symbol,Real})

        no_triplets::Int64 = size(triplets,1)
        no_items::Int64 = maximum(triplets)

        if dimensions > 0
            X = Embedding(randn(maximum(triplets), dimensions))
        else
            throw(ArgumentError("Dimensions must be >= 1"))
        end

        @check_embedding_conditions
        @check_tste_params

        new(triplets, dimensions, params, X, no_triplets, no_items)
    end

    """
    Constructor that takes an initial condition.
    """
    function tSTE(
        triplets::Array{Int64,2},
        params::Dict{Symbol,Real},
        X::Embedding)

        no_triplets::Int64 = size(triplets,1)
        no_items::Int64 = maximum(triplets)
        dimensions = size(X,2)

        @check_embedding_conditions
        @check_tste_params

        new(triplets, dimensions, params, X, no_triplets, no_items)
    end
end

function α(te::tSTE)
    return te.params[:α]
end

function λ(te::tSTE)
    return te.params[:λ]
end

function gradient(te::tSTE)

    P::Float64 = 0.0
    C::Float64 = 0.0 + λ(te) * sum(X(te).^2) # Initialize cost including l2 regularization cost

    sum_X = zeros(Float64, no_items(te), )
    K = zeros(Float64, no_items(te), no_items(te))
    Q = zeros(Float64, no_items(te), no_items(te))

    constant::Float64 = (α(te) + 1) / α(te)

    # Compute t-Student kernel for each point
    # i,j range over points; k ranges over dimensions
    for k in 1:dimensions(te), i in 1:no_items(te)
        @inbounds sum_X[i] += X(te)[i,k] * X(te)[i,k] # Squared norm
    end

    for j in 1:no_items(te), i in 1:no_items(te)
        @inbounds K[i,j] = sum_X[i] + sum_X[j]
        for k in 1:dimensions(te)
            # K[i,j] = (1 + ||x_i - x_j||_2^2/α) ^ (-(α+1)/2),
            # which is exactly the numerator of p_{i,j,k} in the lower right of
            # t-STE paper page 3.
            # The proof follows because ||a - b||_2^2 = a'*a + b'*b - 2a'*b
            @inbounds K[i,j] += -2 * X(te)[i,k] * X(te)[j,k]
        end
        @inbounds Q[i,j] = (1 + K[i,j] / α(te)) ^ -1
        @inbounds K[i,j] = (1 + K[i,j] / α(te)) ^ ((α(te) + 1) / -2)
    end

    nthreads::Int64 = Threads.nthreads()
    work_ranges = partition_work(no_triplets(te), nthreads)

    # Define costs and gradient vectors for each thread
    Cs = zeros(Float64, nthreads, )
    ∇Cs = [zeros(Float64, no_items(te), dimensions(te)) for _ = 1:nthreads]
    
    Threads.@threads for tid in 1:nthreads
        Cs[tid] = gradient_kernel(te, K, Q, ∇Cs[tid], constant, work_ranges[tid])
    end

    C += sum(Cs)
    ∇C = ∇Cs[1]
    
    for i in 2:length(∇Cs)
        ∇C .+= ∇Cs[i]
    end

    for i in 1:dimensions(te), n in 1:no_items(te)
        # The 2λX is for regularization: derivative of L2 norm
        @inbounds ∇C[n,i] = - ∇C[n, i] + 2*λ(te) * X(te)[n, i]
    end

    println(C)
    return C, ∇C
end

function gradient_kernel(te::tSTE,
                        K::Array{Float64,2},
                        Q::Array{Float64,2},
                        ∇C::Array{Float64,2},
                        constant::Float64,
                        triplets_range::UnitRange{Int64})

    C::Float64 = 0.0
    
    for t in triplets_range
        @inbounds triplets_A = triplets(te)[t, 1]
        @inbounds triplets_B = triplets(te)[t, 2]
        @inbounds triplets_C = triplets(te)[t, 3]

        # Compute the log probability for each triplet
        # This is exactly p_{ijk}, which is the equation in the lower-right of page 3 of the t-STE paper.
        @inbounds P = K[triplets_A, triplets_B] / (K[triplets_A, triplets_B] + K[triplets_A, triplets_C])
        C += -log(P)

        for i in 1:dimensions(te)
            # Calculate the gradient of *this triplet* on its points.
            @inbounds A_to_B = ((1 - P) * Q[triplets_A, triplets_B] * (X(te)[triplets_A, i] - X(te)[triplets_B, i]))
            @inbounds A_to_C = ((1 - P) * Q[triplets_A, triplets_C] * (X(te)[triplets_A, i] - X(te)[triplets_C, i]))

            @inbounds ∇C[triplets_A, i] +=   constant * (A_to_C - A_to_B)
            @inbounds ∇C[triplets_B, i] +=   constant *  A_to_B
            @inbounds ∇C[triplets_C, i] += - constant *  A_to_C
        end
    end
    return C
end
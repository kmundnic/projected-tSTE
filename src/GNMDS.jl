abstract type AbstractGNMDS <: TripletEmbedding end

losses = [:hinge, :smooth_hinge, :log, :exp]

# We use metaprogramming to generated different possible
# structs (each for a different possible loss function).
# Then, we can call the gradient for the type AbstractGNMDS,
# but each gradient will be called using multiple dispatch.
for symbol in losses
        
    @eval struct $(Symbol(string("GNMDS_", symbol))) <: AbstractGNMDS
            triplets::Array{Int64,2}
            dimensions::Int64
            X::Embedding
            no_triplets::Int64
            no_items::Int64

            function $(Symbol(string("GNMDS_", symbol)))(
                loss::String,
                triplets::Array{Int64,2},
                dimensions::Int64,
                X::Embedding)
                
                no_triplets::Int64 = size(triplets,1)
                no_items::Int64 = maximum(triplets)

                @check_embedding_conditions
                
                new(triplets, dimensions, X, no_triplets, no_items)
            end

            """
            Constructor that initializes with a random (normal)
            embedding.
            """
            function $(Symbol(string("GNMDS_", symbol)))(
                triplets::Array{Int64,2},
                dimensions::Int64)

                no_triplets::Int64 = size(triplets,1)
                no_items::Int64 = maximum(triplets)

                if dimensions > 0
                    X = Embedding(0.0001*randn(maximum(triplets), dimensions))
                else
                    throw(ArgumentError("Dimensions must be >= 1"))
                end

                @check_embedding_conditions

                new(triplets, dimensions, X, no_triplets, no_items)
            end

            """
            Constructor that takes an initial condition.
            """
            function $(Symbol(string("GNMDS_", symbol)))(
                triplets::Array{Int64,2},
                X::Embedding)

                no_triplets::Int64 = size(triplets,1)
                no_items::Int64 = maximum(triplets)
                dimensions = size(X,2)

                @check_embedding_conditions

                new(triplets, dimensions, X, no_triplets, no_items)
            end
        end
end

function kernel(te::GNMDS_hinge, D::Array{Float64,2})

    slack = zeros(no_triplets(te))
    
    for t in 1:no_triplets(te)
        @inbounds i = triplets(te)[t,1]
        @inbounds j = triplets(te)[t,2]
        @inbounds k = triplets(te)[t,3]

        @inbounds slack[t] = max(D[i,j] + 1 - D[i,k], 0)
    end
    return Dict(:slack => slack)
end

function kernel(te::GNMDS_smooth_hinge, D::Array{Float64,2})
    
    weights = zeros(no_triplets(te))
    slack = zeros(no_triplets(te))

    for t in 1:no_triplets(te)
        @inbounds i = triplets(te)[t,1]
        @inbounds j = triplets(te)[t,2]
        @inbounds k = triplets(te)[t,3]        
        
        @inbounds weights[t] = exp(1 + D[i,j] - D[i,k])
        @inbounds slack[t] = log(1 + weights[t])
        @inbounds weights[t] = weights[t] / (1 + weights[t])

    end
    return Dict(:slack => slack, :weights => weights)
end


function kernel(te::GNMDS_log, D::Array{Float64,2})
    
    weights = zeros(no_triplets(te))
    slack = zeros(no_triplets(te))

    for t in 1:no_triplets(te)
        @inbounds i = triplets(te)[t,1]
        @inbounds j = triplets(te)[t,2]
        @inbounds k = triplets(te)[t,3]        
        
        @inbounds weights[t] = exp(D[i,j] - D[i,k])
        @inbounds slack[t] = log(1 + weights[t])
        @inbounds weights[t] = weights[t] / (1 + weights[t])

    end
    return Dict(:slack => slack, :weights => weights)
end

function kernel(te::GNMDS_exp, D::Array{Float64,2})
    
    slack = zeros(no_triplets(te))

    for t in 1:no_triplets(te)
        @inbounds i = triplets(te)[t,1]
        @inbounds j = triplets(te)[t,2]
        @inbounds k = triplets(te)[t,3]        
        
        # This operation is slow with negative values,
        # and Yeppp takes vectors only...
        @inbounds slack[t] = exp(D[i,j] - D[i,k])
    end
    return Dict(:slack => slack, :weights => slack)
end

function distances(te::AbstractGNMDS)
    sum_X = zeros(Float64, no_items(te), )
    D = zeros(Float64, no_items(te), no_items(te))

    # Compute normal density kernel for each point
    # i,j range over points; k ranges over dimensions
    for k in 1:dimensions(te), i in 1:no_items(te)
        @inbounds sum_X[i] += X(te)[i,k] * X(te)[i,k]
    end

    for j in 1:no_items(te), i in 1:no_items(te)
        @inbounds D[i,j] = sum_X[i] + sum_X[j]
        for k in 1:dimensions(te)
            @inbounds D[i,j] += -2 * X(te)[i,k] * X(te)[j,k]
        end
    end
    return D
end

function gradient(te::AbstractGNMDS)

    D = distances(te)
    params = kernel(te, D)
    C = sum(params[:slack])

    # We use single thread here since it is faster than
    # multithreading in Julia v1.0.3
    # We leave the multithreaded version of gradient_kernel
    # for the future
    ∇C = gradient_kernel(te, params)


    return C, ∇C

end

function gradient_kernel!(te::AbstractGNMDS,
                         violations::Array{Bool,1},
                         ∇C::Array{Float64,2},
                         triplets_range::UnitRange{Int64})
    
    for t in triplets_range
        if violations[t]
            @inbounds i = triplets(te)[t,1]
            @inbounds j = triplets(te)[t,2]
            @inbounds k = triplets(te)[t,3]

            for d in 1:dimensions(te)
                @inbounds dx_j = X(te)[i,d] - X(te)[j,d]
                @inbounds dx_k = X(te)[i,d] - X(te)[k,d]
                
                @inbounds ∇C[i,d] +=   2 * (dx_j - dx_k)
                @inbounds ∇C[j,d] += - 2 * dx_j
                @inbounds ∇C[k,d] +=   2 * dx_k
            end
        end
    end

    return ∇C
end

function gradient_kernel(te::GNMDS_hinge,
                         params::Dict{Symbol,Array{Float64,1}})
    
    violations = zeros(Bool, no_triplets(te))
    @. violations = params[:slack] > 0
    ∇C = zeros(Float64, no_items(te), dimensions(te))

    for t in eachindex(violations)
        if violations[t]
            # We obtain the indices for readability
            @inbounds i = triplets(te)[t,1]
            @inbounds j = triplets(te)[t,2]
            @inbounds k = triplets(te)[t,3]

            for d in 1:dimensions(te)
                @inbounds dx_j = X(te)[i,d] - X(te)[j,d]
                @inbounds dx_k = X(te)[i,d] - X(te)[k,d]
                
                @inbounds ∇C[i,d] +=   2 * (dx_j - dx_k)
                @inbounds ∇C[j,d] += - 2 * dx_j
                @inbounds ∇C[k,d] +=   2 * dx_k
            end
        end
    end

    return ∇C
end

for symbol in [:smooth_hinge, :log, :exp]
    
    @eval function gradient_kernel(te::$(Symbol(string("GNMDS_", symbol))),
                             params::Dict{Symbol,Array{Float64,1}})
        
        violations = zeros(Bool, no_triplets(te))
        @. violations = params[:slack] > 0
        ∇C = zeros(Float64, no_items(te), dimensions(te))

        for t in eachindex(violations)
            if violations[t]
                # We obtain the indices for readability
                @inbounds i = triplets(te)[t,1]
                @inbounds j = triplets(te)[t,2]
                @inbounds k = triplets(te)[t,3]
                @inbounds w = params[:weights][t]

                for d in 1:dimensions(te)
                    @inbounds dx_j = 2 * w * (X(te)[i,d] - X(te)[j,d])
                    @inbounds dx_k = 2 * w * (X(te)[i,d] - X(te)[k,d])

                    @inbounds ∇C[i,d] +=   (dx_j - dx_k)
                    @inbounds ∇C[j,d] += - dx_j
                    @inbounds ∇C[k,d] +=   dx_k
                end
            end
        end

        return ∇C
    end
end
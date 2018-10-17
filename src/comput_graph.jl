export AbstractNode, LeafNode
export Variable, Node, CachedNode, forward, gradient, backward, value, args, arg, operator
export Tracked
export register

# export register!

abstract type Operator end

module Trait
import YAAD: Operator

struct Method{FT} <: Operator
    f::FT
end

struct Broadcasted{FT} <: Operator
    f::FT
end
end # Trait

abstract type AbstractNode end
abstract type LeafNode <: AbstractNode end

"""
    Variable{T} <: LeafNode

A kind of leaf node. A general type for variables in a comput-graph.
The gradient will be accumulated to `var.grad`.
"""
mutable struct Variable{T} <: LeafNode
    value::T
    grad::T

    Variable(val::T) where T = new{T}(val)
    Variable(val::T, grad::T) where T = new{T}(val)
end

"""
    Node{FT, ArgsT} <: AbstractNode

General node in a comput-graph. It stores a callable operator `f` of type `FT`
and its arguments `args` in type `ArgsT` which should be a tuple.
"""
struct Node{FT <: Operator, ArgsT <: Tuple} <: AbstractNode
    f::FT
    args::ArgsT
end

# wrap function to Method
Node(f::Function, args) = Node(Trait.Method(f), args)

"""
    CachedNode{NT, OutT} <: AbstractNode

Stores the cache of output with type `OutT` from a node of
type `NT` in comput-graph. CachedNode is mutable, its output
can be updated by [`forward`](@ref).
"""
mutable struct CachedNode{NT <: AbstractNode, OutT} <: AbstractNode
    node::NT
    output::OutT
end

CachedNode(f, args, output) = CachedNode(Node(f, args), output)

function CachedNode(f, args)
    node = Node(f, args)
    output = forward(node)
    CachedNode(node, output)
end

Base.size(x::AbstractNode) = size(value(x))
Base.size(x::AbstractNode, d::Int) = size(value(x), d)
Base.similar(x::AbstractNode) = Variable(similar(value(x)))
Base.similar(x::AbstractNode, dims::Dims) = Variable(similar(value(x), dims))
Base.similar(x::AbstractNode, element_type::Type{S}, dims::Dims) where S = Variable(similar(value(x), element_type, dims))
Base.axes(x::AbstractNode) = axes(value(x))

arg(x::Node, i::Int) = x.args[i]
args(x::Node) = x.args
operator(x::Node) = x.f

arg(x::CachedNode, i::Int) = x.node.args[i]
args(x::CachedNode) = x.node.args
operator(x::CachedNode) = x.node.f

Base.eltype(x::AbstractNode) = eltype(value(x))

"""
    value(node)

Returns the value when forwarding at current node. `value` is different
than [`forward`](@ref) method, `value` only returns what the node contains,
it will throw an error, if this node does not contain anything.
"""
function value end

# forward other values
value(x) = x

function value(x::T) where {T <: AbstractNode}
    error(
        "Expected value in this node $x of type $T ",
        "check if you defined a non-cached node",
        " or overload value function for your node."
    )
end

value(x::Variable) = x.value
value(x::CachedNode) = value(x.output)

"""
    forward(node) -> output

Forward evaluation of the comput-graph. This method will call the operator
in the comput-graph and update the cache.

    forward(f, args...) -> output

For function calls.
"""
function forward end

forward(x) = x
forward(node::LeafNode) = value(node)
forward(node::Node) = forward(node.f, map(forward, node.args)...)
forward(node::CachedNode) = (node.output = forward(node.node))
forward(op::Operator, args...) = op.f(args...)
forward(op::Trait.Broadcasted, args...) = Broadcast.broadcasted(op.f, args...)

# better error msg
# NOTE: Colon is a Function, this can have ambiguity
# we force to use a trait here.
forward(::Function, args...) =
    error(
        "please wrap your operator as subtype of Operator",
        " directly forward a function may cause ambiguity"
    )

"""
    backward(node) -> nothing

Backward evaluation of the comput-graph.
"""
function backward end

# return nothing for non-node types
backward(x, grad) = nothing
backward(x::AbstractNode) = backward(x::AbstractNode, one(eltype(x)))

function backward(x::Variable, grad)
    if isdefined(x, :grad)
        x.grad += grad
    else
        x.grad = grad
    end
    nothing
end

backward(node::CachedNode, grad) = backward(node, node.node.f, grad)
backward(node::CachedNode, op::Operator, grad) = backward(node, op.f, grad)

function backward(node::CachedNode, f, grad)
    backward_type_assert(node, grad)
    # TODO: replace with @assert when there is a compiler option for it
    @boundscheck backward_size_assert(node, grad)

    grad_inputs = gradient(node, grad)
    for (each, each_grad) in zip(args(node), grad_inputs)
        backward(each, each_grad)
    end
    nothing
end

"""
    backward_type_assert(node, grad)

throw more readable error msg for backward type check.
"""
function backward_type_assert end

# mute the compiler error msg
backward_type_assert(args...) = true

backward_type_assert(node::CachedNode{<:AbstractNode, T}, grad::T) where T = true
backward_type_assert(node::CachedNode{<:AbstractNode, T1}, grad::T2) where {T1, T2} =
    error("Gradient is expected to have the same",
          " type with outputs, expected $T1",
          " got $T2")

function backward_size_assert(node::CachedNode, grad)
    size(node.output) == size(grad) ||
        error(
            "gradient should have the same size with output,",
            " expect size $(size(node.output)), got $(size(grad))"
        )
end

"""
    gradient(node, grad)

Returns the gradient.
"""
function gradient end

## CachedNode
# 1. general interface
gradient(x::CachedNode, grad) = gradient(x.node.f, grad, x.output, map(value, x.node.args)...)
gradient(x::Node, grad) = gradient(x.f, grad, map(value, x.args)...)

# NOTE: operators help to define different grads when the fn is the same
# e.g Broadcasted{typeof(sin)} and `sin`

# 2. forward operator to function type
# this simplifies some operator's definition
gradient(x::Operator, grad, output, args...) =
    gradient(x.f, grad, output, args...)

# gradient(fn, grad, args...) =
#     error(
#         "gradient of operator $fn is not defined\n",
#         "Possible Fix:\n",
#         "define one of the following:\n",
#         "1. gradient(::typeof($fn), grad, args...)\n",
#         "2. gradient(op::Trait.Method{typeof($fn)}, grad, args...)\n",
#         "3. gradient(op::Trait.Broadcasted{typeof($fn)}, grad, args...)\n"
#     )

gradient(fn, grad, output, args...) =
    error(
        "gradient of operator $fn is not defined\n",
        "Possible Fix:\n",
        "define one of the following:\n",
        "1. gradient(::typeof($fn), grad, output, args...)\n",
        "2. gradient(op::Trait.Method{typeof($fn)}, grad, output, args...)\n",
        "3. gradient(op::Trait.Broadcasted{typeof($fn)}, grad, output, args...)\n"
    )


register(f, args...) = CachedNode(f, args)
################################
# mutable struct Tracked{T} <: AbstractNode
#     value::T
# end
#
# # forward(x::Tracked) = x
#
# const GLOBAL_TAPE = IdDict{Tracked, AbstractNode}()
#
# register!(tape::IdDict, x) = (tracked = Tracked(x); tape[tracked] = Variable(x); tracked)
#
# function register!(tape::IdDict, f, args)
#     node = Node(f, args)
#     output = forward(node)
#     cached = CachedNode(node, output)
#     tracked = Tracked(output)
#     tape[tracked] = cached
#     tracked
# end
#
# register(f, args...) = register!(GLOBAL_TAPE, f, args)
#
# backward(x::Tracked{T}, grad=one(T)) where T = backward(GLOBAL_TAPE, x, grad)
#
# function backward(tape::IdDict, x::Tracked{T}, grad=one(T)) where T
#     node = tape[x]
#     backward(node, grad)
# end
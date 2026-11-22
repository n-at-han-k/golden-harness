# frozen_string_literal: true

require "set"
require "unparser"

module GoldenHarness
  # The Ruby side: builders for `parser` AST nodes, named after what they mean
  # rather than after the node type, in the same shape as ast/gtk/dsl.rb.
  #
  # Nothing here produces text. Unparser owns every layout question -- where a
  # line breaks, whether a block is `do ... end` or braces, which parentheses
  # are needed -- so the emitter cannot get them wrong, and rubocop applies the
  # house style afterwards. The whole class of bug the string templates had
  # (a `do ... end` binding to the wrong call, a dangling `end`, an operator
  # left at the end of a line) is unreachable from here.
  module DSL
    # One statement list. `nil` for empty, the statement itself when there is
    # exactly one: that is what `parser` produces, and unparser expects it.
    def Body(statements)
      kids = statements.flatten.compact
      return nil if kids.empty?
      return kids.first if kids.one?

      n(:begin, *kids)
    end

    def Str(value) = n(:str, value.to_s)

    def Sym(value) = n(:sym, value.to_sym)

    def Int(value) = n(:int, Integer(value))

    def Float_(value) = n(:float, Float(value))

    def True_ = n(:true)

    def False_ = n(:false)

    def Nil_ = n(:nil)

    def Self_ = n(:self)

    def Lvar(name) = n(:lvar, name.to_sym)

    def Ivar(name) = n(:ivar, :"@#{name}")

    def Const(name, parent = nil) = n(:const, parent, name.to_sym)

    # A dotted constant path, `Foo::Bar` -> nested const nodes.
    def ConstPath(name)
      name.to_s.split("::").inject(nil) { |parent, part| Const(part, parent) }
    end

    def Local(name, value) = n(:lvasgn, name.to_sym, value)

    def IvarSet(name, value) = n(:ivasgn, :"@#{name}", value)

    def Constant(name, value) = n(:casgn, nil, name.to_sym, value)

    # `recv.name = value`. An assignment to an attribute is a send whose
    # selector ends in `=`, which is how unparser knows to print it infix.
    def AttrSet(receiver, name, value) = n(:send, receiver, :"#{name}=", value)

    def IndexSet(receiver, *index_and_value) = n(:indexasgn, receiver, *index_and_value)

    def Index(receiver, *indices) = n(:index, receiver, *indices)

    # The C++ author's parentheses, kept as a node.
    #
    # Load-bearing, not decoration: unparser does NOT parenthesise by
    # precedence, so `s(:and, x, s(:or, a, b))` prints as `x && a || b`, which
    # reparses as `(x && a) || b`. The grouping has to be in the tree. rubocop
    # drops the ones that turn out to be redundant.
    def Paren(value) = n(:begin, value)

    def Call(receiver, name, *args) = n(:send, receiver, name.to_sym, *args)

    # A call with a block. Unparser decides `do ... end` versus braces, and
    # both parse to this same tree, so the choice cannot change the meaning.
    def CallBlock(call, params, body) = n(:block, call, BlockParams(params), body)

    def Params(names) = n(:args, *names.map { Param(_1) })

    # A block taking exactly one parameter is a `procarg0`, which is how
    # `parser` distinguishes `{ |e| }` from a method's `(e)`. Built as a plain
    # `arg`, unparser writes the destructuring form `|e,|`.
    def BlockParams(names)
      return n(:args, n(:procarg0, Param(names.first))) if names.one?

      Params(names)
    end

    def Param(name) = n(:arg, name.to_sym)

    def Lambda(params, body) = CallBlock(Call(nil, :lambda), params, body)

    def And(left, right) = n(:and, left, right)

    def Or(left, right) = n(:or, left, right)

    def Not(value) = n(:send, value, :!)

    def Binary(left, operator, right) = n(:send, left, operator.to_sym, right)

    # `0...n` -- an exclusive range, which is its own node type rather than an
    # operator send.
    def ExclusiveRange(from, to) = n(:erange, from, to)

    def OpAssign(target, operator, value) = n(:op_asgn, target, operator.to_sym, value)

    def LocalTarget(name) = n(:lvasgn, name.to_sym)

    def IvarTarget(name) = n(:ivasgn, :"@#{name}")

    def If(condition, then_body, else_body = nil) = n(:if, condition, then_body, else_body)

    # `unless cond` is an `if` with the branches the other way round, which is
    # also how `parser` represents it, so there is no separate node type.
    def Unless(condition, body) = n(:if, condition, nil, body)

    def While(condition, body) = n(:while, condition, body)

    def Loop(body) = CallBlock(Call(nil, :loop), [], body)

    def Case(subject, whens, else_body) = n(:case, subject, *whens, else_body)

    def When(values, body) = n(:when, *values, body)

    def Return(value = nil) = value ? n(:return, value) : n(:return)

    def Next_ = n(:next)

    def Break_ = n(:break)

    def Raise = Call(nil, :raise)

    def Def(name, params, body) = n(:def, name.to_sym, Params(params), body)

    def Class_(name, body) = n(:class, ConstPath(name), nil, body)

    def Module_(name, body) = n(:module, ConstPath(name), body)

    def Super(*args) = n(:super, *args)

    # A string with interpolations. A run of plain text is a `str`, anything
    # else is wrapped so unparser writes `#{...}`.
    def Dstr(parts)
      return Str("") if parts.empty?
      return parts.first if parts.one? && parts.first.type == :str

      n(:dstr, *parts)
    end

    def Interp(value) = n(:begin, value)

    # Every `lvar` that nothing in `node` assigns, rewritten as a receiverless
    # send.
    #
    # Unparser VERIFIES a dynamic string by printing it and parsing it back,
    # against the local scope it has tracked so far. `"#{len}"` is accepted
    # where `len = ...` precedes it, because the re-parse agrees it is an
    # lvar -- and REFUSED, with UnsupportedNodeError for the whole method,
    # where nothing assigns it, because then the re-parse says send.
    #
    # The emitter reads whether a name is a local off the oracle, which answers
    # for the C++: a function PARAMETER is a local there, and in the Ruby it is
    # an argument that no `lvasgn` mentions. Reconciled here, over the finished
    # method, where every binding the Ruby actually has is visible.
    def sends_for_free_names(node, bound = nil)
      return node unless node.is_a?(::Parser::AST::Node)

      # Recomputed at each METHOD. Taken over the whole file, a name bound in
      # one method kept its `lvar` spelling in another where nothing binds it,
      # and unparser -- which tracks the scope it is emitting -- refused the
      # string it appeared in. `path` is a local in one method of
      # vfs_openvfs.cpp and an interpolated free name in another.
      bound = bindings(node) if bound.nil? || %i[def defs].include?(node.type)
      # A name that is not a plain identifier is left as it is. `lvar` will
      # print anything; a send will not, and syncresult.cpp reached here
      # holding an `lvar` called `:"this ="` -- a malformed node from further
      # up, which converting turned into an unparsable one.
      return n(:send, nil, node.children.first) if
        node.type == :lvar && !bound.include?(node.children.first) &&
        node.children.first.to_s.match?(/\A[a-z_]\w*[?!]?\z/)

      node.updated(nil, node.children.map { sends_for_free_names(_1, bound) })
    end

    BINDING_TYPES = %i[lvasgn arg optarg restarg kwarg kwoptarg blockarg
                       procarg0 shadowarg op_asgn or_asgn and_asgn].freeze

    def bindings(node, into = Set.new)
      return into unless node.is_a?(::Parser::AST::Node)

      if BINDING_TYPES.include?(node.type)
        target = node.children.first
        into << target if target.is_a?(Symbol)
        into.merge(bindings(target)) if target.is_a?(::Parser::AST::Node)
      end
      node.children.each { bindings(_1, into) }
      into
    end

    private

      def n(type, *children) = ::Parser::AST::Node.new(type, children)
  end
end

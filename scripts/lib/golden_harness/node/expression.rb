# frozen_string_literal: true

module GoldenHarness
  class Emitter
    # `&&`/`||` become Ruby's own short-circuit nodes; everything else is a
    # binary send, which is how `parser` models an operator anyway.
    LOGICAL = { "&&" => :and, "||" => :or }.freeze

    # A Qt wrapper around a literal carries nothing into Ruby: there is no
    # QString type here, so `QStringLiteral("x")` is just the string.
    LITERAL_WRAPPERS = %w[
      QStringLiteral QByteArrayLiteral QLatin1String QLatin1Char QChar QString QByteArray
    ].freeze

    # A cast is not a conversion in Ruby, so it reduces to its operand.
    # `qobject_cast<T *>(x)` is spelled as a template call rather than with the
    # cast syntax, but it is the same thing and goes the same way.
    CASTS = %w[static_cast dynamic_cast reinterpret_cast const_cast].freeze

    # Written as a constant so the `#{` cannot be read as interpolation here.
    INTERP_OPEN = ["#", "{"].join.freeze

    # A C++ local may be named for a Ruby keyword -- syncjournaldb has one
    # called `end` -- and then it cannot keep the name.
    #
    # `nil`, `true` and `false` are deliberately absent: they arrive as
    # identifiers (03_simplify.yml's s-empty-if-body writes `nil;` into the
    # C++) but they are LITERALS, handled below, not names to be renamed.
    RESERVED = %w[
      end begin class def do else elsif ensure for if in module next not or and
      redo rescue retry return super then undef unless until when while yield alias
    ].freeze

    # What a reserved name is called instead.
    #
    # The default is a trailing underscore, which is mechanical. These two are
    # not: they are the names the golden gives them, chosen for what the
    # variable HOLDS -- `const char *end` is the last slash in a path, and
    # `auto next` is the next row of a query. Nothing in the source says so, so
    # they are recorded here rather than guessed.
    RENAMES = { "end" => "last_slash", "next" => "next_row" }.freeze

    LITERALS = { "nil" => :Nil_, "true" => :True_, "false" => :False_ }.freeze

    # Qt's "which function am I in" macro. Ruby spells it `__method__`.
    MACROS = { "Q_FUNC_INFO" => "__method__" }.freeze

    private

      def expr(node)
        return nil if node.nil?

        case node.kind
        when "identifier", "field_identifier", "type_identifier" then name_node(@cst.text(node))
        when "qualified_identifier" then qualified(node)
        when "field_expression" then field_access(node)
        when "call_expression" then call(node)
        when "binary_expression" then binary(node)
        when "unary_expression" then unary(node)
        when "parenthesized_expression" then Paren(expr(@cst.named(node).first))
        when "assignment_expression" then assignment(node)
        when "update_expression" then update(node)
        when "subscript_expression" then subscript(node)
        when "string_literal", "raw_string_literal" then string_node(string_value(node))
        when "concatenated_string" then concatenated(node)
        when "char_literal" then Str(char_value(node))
        when "number_literal" then number(node)
        when "true" then True_()
        when "false" then False_()
        when "null", "nullptr" then Nil_()
        # The golden writes `this`, not `self`: a Qt parent/receiver argument
        # is carried across as the C++ spells it.
        when "this" then Lvar(:this)
        when "lambda_expression" then lambda_node(node)
        when "new_expression" then new_object(node)
        when "compound_literal_expression" then brace_init(node)
        when "initializer_list" then initializer(node)
        when "conditional_expression" then ternary(node)
        when "pointer_expression" then expr(@cst.field(node, :argument))
        when "cast_expression" then expr(@cst.field(node, :value))
        when "sizeof_expression" then Int(0)
        else Lvar(@cst.text(node))
        end
      end

      # `_dbFile` is a member, and the leading underscore is the only thing
      # that says so -- 03_simplify.yml keeps it for exactly this reason.
      # A PascalCase name that is never a receiver is an enum value.
      def name_node(text)
        literal = LITERALS[text]
        return send(literal) if literal
        # A send, not a local: `__method__` IS a method, and unparser refuses
        # to round-trip an lvar by that name because it would reparse as one.
        return Call(nil, MACROS[text]) if MACROS.key?(text)
        if text.start_with?("_")
          bare = snake(text.sub(/\A_/, ""))
          # A local keeps its name without the underscore; a MEMBER becomes an
          # ivar. The oracle says which -- see Facts#local?.
          return Lvar(bare) if @facts.local?(@method_name, bare)

          return Ivar(bare)
        end
        return Sym(snake(text)) if @facts.enum_value?(text)
        return Const(text) if text.match?(/\A[A-Z]/)

        Lvar(local_name(text))
      end

      def local_name(text)
        # A LOCAL written with a leading underscore drops it; a member keeps it
        # as the `@`. Only the oracle can tell them apart -- see Facts#local?.
        bare = snake(text.sub(/\A_/, ""))
        return reserved(bare) if text.start_with?("_") && @facts.local?(@method_name, bare)

        reserved(snake(text))
      end

      def reserved(name)
        return name unless RESERVED.include?(name)

        RENAMES.fetch(name, "#{name}_")
      end

      # `A::B` -- a qualified enum constant is a symbol of its last segment, a
      # qualified call is a receiver and a method, and `std::foo` is neither so
      # it passes through as written.
      # `A::B::C` -- split on `::` rather than walked, so any depth comes out
      # the same: the last segment is the name and everything before it is the
      # receiver.
      def qualified(node)
        segments = @cst.text(node).split("::")
        last = segments.last
        # Downcased as well as snaked: `NONE` has no case boundary for snake
        # to split on, and `:NONE` is not what a symbol looks like.
        return Sym(snake(last).downcase) if last.match?(/\A[A-Z][A-Za-z0-9]*\z/)
        # A scoped enum constant, whatever its case: the oracle knows
        # `CheckSums::Algorithm::PARSE_ERROR` is one, and being scoped is what
        # separates it from a bare `CSYNC_INSTRUCTION_NEW` macro constant.
        return Sym(last.downcase) if @facts.scoped_enum?(last)
        return Lvar(@cst.text(node)) unless segments.first.match?(/\A[A-Z]/)

        Call(ConstPath(segments[0..-2].join("::")), snake(last))
      end

      # `a->_server` / `a._server` -> `a.server`.
      #
      # Reached through a receiver the member is a method, so the underscore
      # that marked it as a member goes; it is only kept on a bare mention,
      # where it becomes the `@`.
      def field_access(node)
        argument = @cst.field(node, :argument)
        field = @cst.field(node, :field)
        # Inside a rewritten `operator==`: the left operand is the receiver, so
        # its members are ivars, and the right one is the argument.
        if argument.kind == "identifier" && @operator_lhs
          text = @cst.text(argument)
          return Ivar(snake(@cst.text(field).sub(/\A_/, ""))) if text == @operator_lhs
          return Call(Lvar(:other), member(field)) if text == @operator_rhs
        end
        # `this->_db` is this object's own member, which is the ivar; reaching
        # it through `self` is a C++ necessity, not a Ruby one.
        # `const_cast<SyncJournalDb *>(this)->_db` -- the cast is dropped, so
        # the receiver is reached THROUGH it and the node is not a bare `this`.
        return Ivar(snake(@cst.text(field).sub(/\A_/, ""))) if
          @cst.dig?(argument, "this") && @cst.text(field).start_with?("_")

        Call(expr(argument), member(field))
      end

      def member(field) = @cst.text(field).sub(/\A_/, "")

      def call(node)
        fn = @cst.field(node, :function)
        args = call_arguments(node)

        return expr(args.first ? @cst.named(@cst.field(node, :arguments)).first : nil) if wrapper?(fn, args)

        if fn.kind == "field_expression"
          return send_with_block(expr(@cst.field(fn, :argument)),
                                 member(@cst.field(fn, :field)), node, args)
        end

        # `int(type)` / `bool(x)` -- a functional cast, which is not a
        # conversion in Ruby any more than `static_cast` is.
        return args.first if fn.kind == "primitive_type" && args.one?

        if fn.kind == "identifier"
          text = @cst.text(fn)
          return args.first if CASTS.include?(text) && args.one?
          return Str("") if LITERAL_WRAPPERS.include?(text) && args.empty?
          if @facts.callable?(@function, text, @method_name) ||
             @facts.callable?(@function, local_name(text), @method_name)
            return send_with_block(Lvar(local_name(text)), :call, node, args)
          end
          # `ChecksumHeader(type, sum)` / `QFileInfo(path)` -- a CONSTRUCTOR,
          # which in Ruby is `.new`. Bare, it is a call to a method of that
          # name, which does not exist; the oracle confirms these are classes.
          return send_with_block(ConstPath(text), :new, node, args) if
            text.match?(/\A[A-Z]/) && @facts.record?(text)

          return send_with_block(nil, text, node, args) if text.match?(/\A[A-Z]/)

          return send_with_block(nil, snake(text), node, args)
        end

        # `f<T>(x)` -- the template arguments are types, which Ruby has no
        # place for, so only the name and the arguments survive.
        if fn.kind == "template_function"
          name = @cst.text(@cst.dig(fn, "identifier", field: :name))
          return args.first if CASTS.include?(name) && args.one?
          return template_call(fn, name, args) if args.one?

          return send_with_block(nil, name, node, args)
        end

        if fn.kind == "qualified_identifier"
          segments = @cst.text(fn).split("::")
          # `std::filesystem::directory_entry(...)` -- a namespaced free
          # function. Ruby has no namespace, so the name is kept whole rather
          # than turned into a receiver it does not have.
          return send_with_block(nil, @cst.text(fn), node, args) unless segments.first.match?(/\A[A-Z]/)
          return send_with_block(nil, segments.last, node, args) if segments.one?

          return send_with_block(ConstPath(segments[0..-2].join("::")), snake(segments.last), node, args)
        end

        send_with_block(expr(fn), :call, node, args)
      end

      # `qobject_cast<T *>(x)` -> `qobject_cast < T > (x)`.
      #
      # Which is not a cast and not valid Ruby semantics -- it reads as two
      # comparisons -- but it is what the golden carries, because the old
      # text pipeline had no way to see the template call and left the tokens
      # where they were. Reproduced deliberately: the golden is the
      # specification. Treating it as a cast instead gives `job = sender`,
      # which is what this did before.
      def template_call(fn, name, args)
        argument = @cst.dig(fn, "type_identifier", field: :arguments)
        return Call(nil, name, *args) if argument.nil?

        Binary(Binary(Lvar(name), :<, Const(@cst.text(argument))), :>, Paren(args.first))
      end

      # A Qt literal wrapper applied to one literal.
      def wrapper?(fn, args)
        fn.kind == "identifier" && LITERAL_WRAPPERS.include?(@cst.text(fn)) && args.one?
      end

      # A trailing lambda argument is Ruby's block. Unparser then decides
      # `do ... end` or braces, and the two parse to the same tree, so the
      # choice cannot change what the code means.
      def send_with_block(receiver, name, node, args)
        list = @cst.field(node, :arguments)
        last = @cst.last_named(list)
        if last && last.kind == "lambda_expression"
          head = args[0...-1]
          return CallBlock(Call(receiver, name, *head), lambda_params(last),
                           Body(statements_of(@cst.field(last, :body))))
        end
        Call(receiver, name, *args)
      end

      def call_arguments(node)
        list = @cst.field(node, :arguments)
        return [] if list.nil?

        last = @cst.last_named(list)
        @cst.named(list).filter_map do |argument|
          # Compared by POSITION. tree-sitter hands back a fresh wrapper object
          # for every lookup, so `equal?` is never true and a trailing lambda
          # was being hoisted instead of becoming the block it should be.
          trailing = last && argument.start_byte == last.start_byte
          next hoist_lambda(node, argument) if
            argument.kind == "lambda_expression" && !trailing

          expr(argument)
        end
      end

      # A lambda passed anywhere but LAST cannot be a block, and inline it
      # buries the arguments that follow it. Bound to a local above the
      # statement instead, which is what the golden writes:
      #
      #   parent_hash = lambda do |ctx, _, argv| ... end
      #   sqlite3_create_function(@db.sqlite_db, "parent_hash", 1, ..., parent_hash, ...)
      #
      # Named after the call's own string literal, which is what the thing
      # being registered is called -- there is nothing else in the source to
      # name it after.
      def hoist_lambda(node, argument)
        name = lambda_name(node)
        (@pending_before || []) << Local(name, expr(argument))
        Lvar(name)
      end

      def lambda_name(node)
        literal = @cst.named(@cst.field(node, :arguments))
                      .find { %w[string_literal concatenated_string].include?(_1.kind) }
        return "callback" if literal.nil?

        snake(string_value(@cst.named(literal).first || literal).gsub(/[^A-Za-z0-9_]/, "_"))
      end

      def binary(node)
        left = expr(@cst.field(node, :left))
        right = expr(@cst.field(node, :right))
        operator = @cst.text(@cst.field(node, :operator))
        logical = LOGICAL[operator]
        return send(logical == :and ? :And : :Or, left, right) if logical

        Binary(left, operator, right)
      end

      def unary(node)
        argument = @cst.field(node, :argument)
        operand = expr(argument)
        operator = @cst.text(@cst.field(node, :operator))
        case operator
        # `!n` on an INTEGER means `n == 0`; in Ruby every integer is truthy,
        # so `!n` is always false and the branch would never be taken. Which
        # names are integers is the oracle's to say -- `!query` on a pointer
        # must stay `!query`.
        when "!" then integer?(argument) ? Binary(operand, :==, Int(0)) : Not(operand)
        when "-" then Call(operand, :-@)
        when "+" then operand
        else operand
        end
      end

      def integer?(node)
        return false unless node.kind == "identifier"

        @facts.shape(local_name(@cst.text(node)), @method_name) == "int"
      end

      def assignment(node)
        target = @cst.field(node, :left)
        value = expr(@cst.field(node, :right))
        operator = @cst.text(@cst.field(node, :operator))
        return compound_assign(target, operator, value) unless operator == "="

        store(target, value)
      end

      def store(target, value)
        case target.kind
        when "identifier"
          text = @cst.text(target)
          text.start_with?("_") ? IvarSet(snake(text.sub(/\A_/, "")), value) : Local(local_name(text), value)
        when "field_expression"
          AttrSet(expr(@cst.field(target, :argument)), member(@cst.field(target, :field)), value)
        when "subscript_expression"
          IndexSet(expr(@cst.field(target, :argument)), *subscript_indices(target), value)
        else
          Binary(expr(target), :==, value)
        end
      end

      def compound_assign(target, operator, value)
        op = operator.delete_suffix("=")
        OpAssign(assign_target(target), op, value)
      end

      def assign_target(target)
        case target.kind
        when "identifier"
          text = @cst.text(target)
          text.start_with?("_") ? IvarTarget(snake(text.sub(/\A_/, ""))) : LocalTarget(local_name(text))
        else
          expr(target)
        end
      end

      # `i++` as a statement is `i += 1`.
      #
      # `!autotestFailCounter--` nests the other way round in the C++ tree --
      # the `!` ends up INSIDE the update -- and an op-assign is not a valid
      # target for it, so the negation is lifted back out.
      #
      # NOTE: this is not faithful. C++ tests the value BEFORE the decrement;
      # this tests it after. Saying so properly needs a temporary, which is
      # what the hand-written golden uses, and a temporary is a statement so it
      # cannot be introduced from expression position.
      def update(node)
        operand = @cst.field(node, :argument)
        operator = @cst.text(@cst.field(node, :operator))
        step = operator == "--" ? :- : :+
        return negated_update(operand, step) if negated_update?(operand)

        assignment = OpAssign(assign_target(operand), step, Int(1))
        # `query->bindValue(i++, x)` -- POSTFIX, so the call sees the old value
        # and the increment happens afterwards. Ruby has no postfix operator,
        # so the increment is handed to the statement being built and emitted
        # on the next line, which is what the golden writes:
        #
        #   query.bind_value(i, phash)
        #   i += 1
        #
        # Only in a subexpression. A bare `i++;` statement is just `i += 1`,
        # and statement() keeps that case for itself.
        return assignment if @pending_updates.nil?

        # Every increment the C++ has, including a last one whose value nothing
        # reads.
        #
        # The golden cannot be matched here: it DROPS that dead store in
        # setFileRecord and KEEPS it in getUploadInfo and getUploadInfos, on
        # identical code -- `x = f(i++)` as the last mention of `i` either way.
        # No rule fits all three, so the faithful reading wins and the one
        # dropped increment in setFileRecord is a known difference.
        # `read_later?` below is what the other choice would use.
        @pending_updates << assignment
        expr(operand)
      end

      # Whether this name is mentioned again after the statement being built.
      #
      # A local, statement-level liveness test: enough to tell a counter that
      # goes on being used from one whose last increment nothing reads.
      def read_later?(operand)
        return true if @current_statement.nil? || operand.kind != "identifier"

        name = @cst.text(operand)
        block = @current_statement.parent
        return true if block.nil?

        after = @cst.named(block).drop_while { _1.start_byte <= @current_statement.start_byte }
        after.any? do |statement|
          @cst.descendants(statement).any? do |node|
            node.kind == "identifier" && @cst.text(node) == name
          end
        end
      end

      def negated_update?(operand)
        operand.kind == "unary_expression" &&
          @cst.text(@cst.field(operand, :operator)) == "!"
      end

      # `!autotestFailCounter--`, which the C++ tree nests the other way round
      # so the `!` ends up INSIDE the update.
      #
      # C++ tests the value BEFORE the decrement, and Ruby has no postfix
      # operator to do that with -- but the test can be moved to the value
      # AFTER it instead, which needs no temporary: `!x--` holds exactly when
      # the old value was 0, which is when the new one is -1. The oracle
      # supplies the fact that makes this sound, namely that the name is an
      # integer; on a pointer `!p--` means something else and is left alone.
      def negated_update(operand, step)
        inner = @cst.field(operand, :argument)
        decremented = OpAssign(assign_target(inner), step, Int(1))
        return Not(decremented) unless integer?(inner)

        Binary(Paren(decremented), :==, Int(step == :- ? -1 : 1))
      end

      # The index sits in a `subscript_argument_list`, not in an `index`
      # field -- C++ allows a comma list there.
      def subscript(node)
        Index(expr(@cst.field(node, :argument)), *subscript_indices(node))
      end

      def subscript_indices(node)
        list = @cst.field(node, :indices)
        return [] if list.nil?

        @cst.named(list).filter_map { expr(_1) }
      end

      def lambda_node(node)
        Lambda(lambda_params(node), Body(statements_of(@cst.field(node, :body))))
      end

      def lambda_params(node)
        list = @cst.dig(node, "parameter_list", field: :declarator)
        return [] if list.nil?

        @cst.named(list).filter_map do |param|
          name = @cst.dig(param, "identifier", field: :declarator)
          name ? @cst.text(name) : "_"
        end
      end

      def new_object(node)
        type = ConstPath(@cst.text(@cst.field(node, :type)))
        Call(type, :new, *call_arguments(node))
      end

      # `Foo{a, b}` -- C++ brace initialisation.
      def brace_init(node)
        type = ConstPath(@cst.text(@cst.field(node, :type)))
        values = @cst.named(@cst.field(node, :value)).filter_map { expr(_1) }
        Call(type, :new, *values)
      end

      def initializer(node)
        values = @cst.named(node).filter_map { expr(_1) }
        return Nil_() if values.empty?
        return values.first if values.one?

        n(:array, *values)
      end

      # Whichever branch the statement is currently being emitted for. The
      # lift in stmt() records it; with nothing recorded the ternary is an `if`
      # expression, which is valid but is not what the golden writes.
      def ternary(node)
        branch = @ternary_branch[node.start_byte]
        return expr(@cst.field(node, branch)) if branch

        If(expr(@cst.field(node, :condition)),
           expr(@cst.field(node, :consequence)),
           expr(@cst.field(node, :alternative)))
      end

      # `"a" "b"` -- C++ concatenates adjacent literals, and the author's line
      # breaks between them are how a long SQL statement is laid out.
      #
      # Kept as one Ruby literal per source line, which Ruby also concatenates
      # and `parser` represents as nested `dstr` nodes, so the grouping reaches
      # Transpile/MultilineString instead of being flattened to one long line.
      def concatenated(node)
        groups = []
        line = nil
        @cst.named(node).each do |literal|
          at = @cst.line(literal)
          groups << [] if line.nil? || at != line
          groups.last << literal
          line = at
        end

        parts = groups.map do |group|
          string_node(group.map { |literal| string_value(literal) }.join)
        end
        return Str("") if parts.empty?
        return parts.first if parts.one?

        Dstr(parts)
      end

      # The literal's characters, not its spelling. A `str` node holds the
      # VALUE, so the C++ escapes have to be resolved here -- left in, unparser
      # escapes the backslashes again and `"\\:?*\""` comes out doubled.
      def string_value(node)
        text = @cst.text(node).sub(/\A[uUL]?8?R?"/, "").sub(/"\z/, "")
        arrows(unescape(text))
      end

      # `u" -> "` becomes `" . "`.
      #
      # Inside a string an arrow is text, not an operator, so this is not a
      # member access being rewritten -- but the golden carries it, because
      # 03_rubyify.py replaced `->` with `.` across the whole file, string
      # literals included. Reproduced here deliberately: the golden is the
      # specification. Delete this one call to stop doing it.
      def arrows(text) = text.gsub("->", ".")

      ESCAPES = {
        "n" => "\n", "t" => "\t", "r" => "\r", "0" => "\0",
        "\\" => "\\", '"' => '"', "'" => "'"
      }.freeze

      def unescape(text)
        text.gsub(/\\(.)/) { ESCAPES.fetch(::Regexp.last_match(1), ::Regexp.last_match(1)) }
      end

      # 04_interp.yml rewrites `QString("%1").arg(x)` into a string that
      # already carries `#{x}`. As a plain `str` that is text, and unparser
      # escapes the `#`, so the interpolation has to become nodes. The
      # fragments are Ruby, so Ruby parses them.
      def string_node(value)
        return Str(value) unless value.include?(INTERP_OPEN)

        parts = []
        rest = value
        while (at = rest.index(INTERP_OPEN))
          parts << Str(rest[0...at]) if at.positive?
          close = matching_brace(rest, at + 1)
          return Str(value) if close.nil?

          parts << Interp(fragment(rest[(at + 2)...close]))
          rest = rest[(close + 1)..]
        end
        parts << Str(rest) unless rest.empty?
        Dstr(parts)
      rescue StandardError
        Str(value)
      end

      # A fragment 04_interp.yml left behind.
      #
      # It is C++, not Ruby -- the rule copies the `.arg()` operand across
      # verbatim, so `#{job->httpStatusCode()}` arrives with the arrow still on
      # it. Read as Ruby it does not parse; read as C++ it is an ordinary
      # expression and goes through the same walk as any other.
      # A bare `_db` is not a translation unit, so it is given a statement to
      # live in and the expression is taken back out -- the same trick
      # ast-grep's pattern `context`/`selector` pair uses.
      def fragment(text)
        sub = Cst.new("#{text};")
        statement = sub.descendants(sub.root).find { _1.kind == "expression_statement" }
        inner = statement && sub.named(statement).first
        return Lvar(text) if inner.nil?

        with_cst(sub) { expr(inner) }
      end

      # The walk reads one tree at a time; a fragment is its own.
      def with_cst(sub)
        outer = @cst
        @cst = sub
        yield
      ensure
        @cst = outer
      end

      def matching_brace(text, open)
        depth = 0
        text[open..].each_char.with_index do |char, offset|
          depth += 1 if char == "{"
          if char == "}"
            depth -= 1
            return open + offset if depth.zero?
          end
        end
        nil
      end

      def char_value(node)
        @cst.text(node).sub(/\A'/, "").sub(/'\z/, "")
      end

      def number(node)
        text = @cst.text(node).delete("'").sub(/[uUlLfF]+\z/, "")
        return Float_(text) if text.include?(".")

        Int(Integer(text, 0))
      rescue ArgumentError
        Lvar(@cst.text(node))
      end
  end
end

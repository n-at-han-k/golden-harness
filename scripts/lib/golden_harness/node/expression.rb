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
    CASTS = %w[static_cast dynamic_cast reinterpret_cast const_cast qobject_cast].freeze

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

    LITERALS = { "nil" => :Nil_, "true" => :True_, "false" => :False_ }.freeze

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
        when "concatenated_string" then string_node(@cst.named(node).map { string_value(_1) }.join)
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
        return Ivar(snake(text.sub(/\A_/, ""))) if text.start_with?("_")
        return Sym(snake(text)) if @facts.enum_value?(text)
        return Const(text) if text.match?(/\A[A-Z]/)

        Lvar(local_name(text))
      end

      def local_name(text)
        name = snake(text)
        RESERVED.include?(name) ? "#{name}_" : name
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
        return Sym(snake(last)) if last.match?(/\A[A-Z][A-Za-z0-9]*\z/)
        return Lvar(@cst.text(node)) unless segments.first.match?(/\A[A-Z]/)

        Call(ConstPath(segments[0..-2].join("::")), snake(last))
      end

      # `a->_server` / `a._server` -> `a.server`.
      #
      # Reached through a receiver the member is a method, so the underscore
      # that marked it as a member goes; it is only kept on a bare mention,
      # where it becomes the `@`.
      def field_access(node)
        receiver = expr(@cst.field(node, :argument))
        Call(receiver, member(@cst.field(node, :field)))
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

        if fn.kind == "identifier"
          text = @cst.text(fn)
          return args.first if CASTS.include?(text) && args.one?
          return Str("") if LITERAL_WRAPPERS.include?(text) && args.empty?
          return send_with_block(Lvar(snake(text)), :call, node, args) if @facts.lambda?(@function, text)
          # `ChecksumHeader(type, sum)` / `QFileInfo(path)` -- a constructor
          # call, so the name is a class name and stays as written.
          return send_with_block(nil, text, node, args) if text.match?(/\A[A-Z]/)

          return send_with_block(nil, snake(text), node, args)
        end

        # `f<T>(x)` -- the template arguments are types, which Ruby has no
        # place for, so only the name and the arguments survive.
        if fn.kind == "template_function"
          name = @cst.text(@cst.dig(fn, "identifier", field: :name))
          return args.first if CASTS.include?(name) && args.one?

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

        @cst.named(list).filter_map { expr(_1) }
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

        OpAssign(assign_target(operand), step, Int(1))
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

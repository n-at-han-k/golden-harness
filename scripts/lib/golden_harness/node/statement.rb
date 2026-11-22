# frozen_string_literal: true

module GoldenHarness
  class Emitter
    ASSERTIONS = %w[OC_ASSERT OC_ASSERT_X OC_ENFORCE OC_ENFORCE_X Q_ASSERT Q_ASSERT_X].freeze
    UNREACHABLE = %w[Q_UNREACHABLE OC_UNREACHABLE].freeze

    # A map whose `[]` default-constructs, which is what lets the C++
    # `entries[k].field = v` work on an absent key. A bare `{}` returns nil and
    # raises, so the block form is required rather than cosmetic.
    MAP_TYPES = /\A(map|unordered_map|QMap|QHash)\z/

    private

      def statements_of(block)
        return [] if block.nil?

        @cst.named(block).flat_map { stmt(_1) }.compact
      end

      # A ternary in a value position becomes an if/else around the WHOLE
      # statement, emitted once per branch.
      #
      # That is the project's convention, forced by Style/DisableSyntax banning
      # the ternary: the golden writes the `qCInfo(...) << (a ? b : c)` chain
      # out twice, once per branch, rather than putting an `if` inside the
      # interpolation. The branch is chosen by recording it and emitting the
      # statement again, so no part of the walk needs to know it is happening.
      def stmt(node)
        lifted = lift_ternary(node)
        return lifted if lifted

        emit_stmt(node)
      end

      def lift_ternary(node)
        found = first_ternary(node)
        return nil if found.nil?

        @ternary_branch[found.start_byte] = :consequence
        consequence = emit_stmt(node)
        @ternary_branch[found.start_byte] = :alternative
        alternative = emit_stmt(node)
        @ternary_branch.delete(found.start_byte)

        [If(expr(@cst.field(found, :condition)), Body(consequence), Body(alternative))]
      end

      # The first ternary this statement owns. One inside a nested lambda
      # belongs to that lambda's own statements and is lifted there instead.
      def first_ternary(node)
        return nil if node.kind == "lambda_expression"

        @cst.named(node).each do |kid|
          next if kid.kind == "lambda_expression"

          if kid.kind == "conditional_expression" && !@ternary_branch.key?(kid.start_byte)
            return kid
          end

          found = first_ternary(kid)
          return found if found
        end
        nil
      end

      def emit_stmt(node)
        case node.kind
        when "comment" then []
        when "compound_statement" then statements_of(node)
        when "declaration" then declaration(node)
        when "struct_specifier", "class_specifier" then hoist(node)
        when "expression_statement" then expression_statement(node)
        when "return_statement" then [return_statement(node)]
        when "continue_statement" then [Next_()]
        when "break_statement" then [Break_()]
        when "if_statement" then [if_statement(node)]
        when "while_statement" then [While(condition(node), Body(statements_of(@cst.field(node, :body))))]
        when "do_statement" then [Loop(Body(statements_of(@cst.field(node, :body))))]
        when "for_range_loop" then [for_range(node)]
        when "for_statement" then [Loop(Body(statements_of(@cst.field(node, :body))))]
        when "switch_statement" then [switch(node)]
        when "labeled_statement" then statements_of(node)
        else [expr(node)].compact
        end
      end

      # A type declared inside a body is still a type: it becomes a constant on
      # the class, so it is hoisted out and nothing is emitted in its place.
      def hoist(node)
        @hoisted << struct(node) if @cst.field(node, :body) && @cst.field(node, :name)
        []
      end

      # A declaration is a local assignment, except when it declares a type.
      def declaration(node)
        type = @cst.field(node, :type)
        if type && %w[struct_specifier class_specifier].include?(type.kind)
          @hoisted << struct(type) if @cst.field(type, :body)
          return []
        end

        return [map_declaration(node)] if map_type(node)

        type = declaration_type(node)

        vexing = vexing_parse(node, type)
        return vexing if vexing

        init = @cst.child(node, "init_declarator", field: :declarator)
        return bare_declaration(node) if init.nil?

        name = @cst.dig(init, "identifier")
        return [] if name.nil?

        # `SqlQuery query(db);` -- a constructor, which the C++ spells like a
        # declaration with an argument list rather than with an `=`.
        arguments = @cst.child(init, "argument_list")
        if arguments
          values = @cst.named(arguments).filter_map { expr(_1) }
          return [Local(local_name(@cst.text(name)), Call(ConstPath(@cst.text(type)), :new, *values))]
        end

        assign(local_name(@cst.text(name)), @cst.field(init, :value))
      end

      def declaration_type(node) = @cst.field(node, :type)

      # C++'s most vexing parse. `SqlQuery pragma1(_db);` is a CONSTRUCTOR, but
      # it is spelled exactly like a function declaration and tree-sitter reads
      # it as one: a function_declarator whose `parameter_list` holds `_db` as
      # a parameter of type `_db`.
      #
      # A class type at statement level settles it -- nobody declares a
      # function returning a Qt class inside a method body -- so the parameters
      # are read back as the arguments they are.
      def vexing_parse(node, type)
        return nil unless type && type.kind == "type_identifier" && @cst.text(type).match?(/\A[A-Z]/)

        declarator = @cst.child(node, "function_declarator", field: :declarator)
        return nil if declarator.nil?

        name = @cst.dig(declarator, "identifier", field: :declarator)
        return nil if name.nil?

        values = @cst.named(@cst.field(declarator, :parameters)).map { fragment(@cst.text(_1)) }
        [Local(local_name(@cst.text(name)), Call(ConstPath(@cst.text(type)), :new, *values))]
      end

      def map_type(node)
        template = @cst.dig(node, "template_type", field: :type)
        return nil unless template

        name = @cst.field(template, :name)
        return nil unless name && MAP_TYPES.match?(@cst.text(name))

        args = @cst.named(@cst.field(template, :arguments))
        value = args[1] && @cst.dig(args[1], "type_identifier")
        value && @cst.text(value)
      end

      def map_declaration(node)
        name = @cst.dig(node, "identifier", field: :declarator)
        value = map_type(node)
        Local(@cst.text(name),
              CallBlock(Call(Const(:Hash), :new), %w[hash key],
                        IndexSet(Lvar(:hash), Lvar(:key), Call(Const(value), :new))))
      end

      # `QElapsedTimer t;` -- declared, not initialised.
      #
      # A class type is still CONSTRUCTED: the C++ runs its default
      # constructor, and the code that follows calls methods on it, so `nil`
      # would raise. A scalar has no value yet and gets one.
      def bare_declaration(node)
        name = @cst.dig(node, "identifier", field: :declarator) || @cst.child(node, "identifier")
        return [] if name.nil?

        [Local(local_name(@cst.text(name)), empty_value(node, @cst.text(name)))]
      end

      # The value a declared-but-uninitialised local starts with.
      #
      # The oracle supplies the declared type, which is the only thing that can
      # answer this: `QVector<T> v;` is `[]`, `QSet<T> s;` is `Set.new`,
      # `QString s;` is `""` and `DownloadInfo res;` runs a constructor. Read
      # off the syntax alone they are indistinguishable -- all four are a
      # type_identifier followed by a name.
      #
      # A scalar stays `nil`: C++ leaves it uninitialised, and `0` would be
      # inventing a value the source does not have.
      def empty_value(node, name)
        case @facts.shape(local_name(name), @method_name)
        when "array" then n(:array)
        when "set" then Call(Const(:Set), :new)
        when "hash" then n(:hash)
        when "string" then Str("")
        when %r{\Aobject:(.+)\z} then Call(ConstPath(::Regexp.last_match(1)), :new)
        else fallback_empty_value(node)
        end
      end

      # No fact for this name, so the syntax decides: a PascalCase type is a
      # class and gets constructed, anything else has no value yet.
      def fallback_empty_value(node)
        type = @cst.field(node, :type)
        return Nil_() unless type && type.kind == "type_identifier"
        return Nil_() unless @cst.text(type).match?(/\A[A-Z]/)

        Call(ConstPath(@cst.text(type)), :new)
      end

      # An immediately-invoked lambda is the value it returns. One whose body
      # is more than a single `return` cannot be reduced that way, so it stays
      # a lambda and is called on the next line.
      def assign(name, value)
        return [Local(name, Nil_())] if value.nil?

        reduced = iife_value(value)
        return [Local(name, reduced)] if reduced

        if (lambda_node = iife_lambda(value))
          return [Local(name, expr(lambda_node)), Call(Lvar(name), :call, *call_arguments(value))]
        end

        [Local(name, expr(value))]
      end

      def iife_value(value)
        lambda_node = iife_lambda(value)
        return nil if lambda_node.nil?

        body = @cst.field(lambda_node, :body)
        kids = @cst.named(body)
        return nil unless kids.one? && kids.first.kind == "return_statement"

        expr(@cst.named(kids.first).first)
      end

      def iife_lambda(value)
        return nil unless value.kind == "call_expression"

        fn = @cst.field(value, :function)
        fn if fn && fn.kind == "lambda_expression"
      end

      def expression_statement(node)
        inner = @cst.named(node).first
        return [] if inner.nil?

        if (call = @cst.dig(inner, "call_expression"))
          name = @cst.field(call, :function)
          if name && name.kind == "identifier"
            text = @cst.text(name)
            return [Unless(assert_condition(call), Raise())] if ASSERTIONS.include?(text)
            return [Raise()] if UNREACHABLE.include?(text)
          end
        end

        return [log(inner)] if log_chain?(inner)

        [expr(inner)].compact
      end

      def assert_condition(call)
        arg = @cst.named(@cst.field(call, :arguments)).first
        arg ? expr(arg) : False_()
      end

      def return_statement(node)
        value = @cst.named(node).first
        return Return() if value.nil?
        # `return {};` -- a default-constructed result, which carries no value.
        return Return(Nil_()) if value.kind == "initializer_list" && @cst.named(value).empty?

        Return(expr(value))
      end

      def if_statement(node)
        alternative = @cst.field(node, :alternative)
        else_body =
          if alternative
            inner = @cst.named(alternative).first
            Body(stmt(inner))
          end
        If(condition(node), Body(statements_of(@cst.field(node, :consequence))), else_body)
      end

      def condition(node)
        clause = @cst.field(node, :condition)
        inner = @cst.named(clause).first
        inner ? expr(inner) : Nil_()
      end

      # `for (auto &e : coll)` -> `coll.each do |e|`.
      def for_range(node)
        name = @cst.dig(node, "identifier", field: :declarator)
        collection = expr(@cst.field(node, :right))
        CallBlock(Call(collection, :each), [@cst.text(name)],
                  Body(statements_of(@cst.field(node, :body))))
      end

      # A C++ `switch` is a Ruby `case`. 03_simplify.yml has already braced
      # every body and dropped the trailing `break`, so each label has exactly
      # one block under it.
      def switch(node)
        subject = condition(node)
        whens = []
        else_body = nil
        pending = []

        @cst.named(@cst.field(node, :body)).each do |label|
          next unless label.kind == "case_statement"

          value = @cst.field(label, :value)
          body = @cst.child(label, "compound_statement")
          # An empty label shares the next one's body: in C++ it falls through,
          # so the faithful Ruby is one `when` with both values.
          if body.nil? || @cst.named(body).empty?
            pending << expr(value) if value
            next
          end

          if value
            whens << When(pending + [expr(value)], Body(statements_of(body)))
          else
            else_body = Body(statements_of(body))
          end
          pending = []
        end

        Case(subject, whens, else_body)
      end
  end
end

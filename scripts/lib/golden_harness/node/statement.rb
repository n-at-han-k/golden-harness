# frozen_string_literal: true

module GoldenHarness
  class Emitter
    ASSERTIONS = %w[OC_ASSERT OC_ASSERT_X OC_ENFORCE OC_ENFORCE_X Q_ASSERT Q_ASSERT_X].freeze
    UNREACHABLE = %w[Q_UNREACHABLE OC_UNREACHABLE].freeze

    # Qt's spelling of `[[fallthrough]]`, which is a STATEMENT rather than an
    # attribute and so is invisible to `fallthrough?`'s attribute test.
    #
    # localdiscoverytracker.cpp writes it 30 times and every one came out as a
    # bare `Q_FALLTHROUGH()` call -- which also kept each label's body
    # non-empty, so the labels never merged into one `when` and each arm
    # collected the arms below it.
    FALLTHROUGH = %w[Q_FALLTHROUGH OC_FALLTHROUGH].freeze

    # `Q_UNUSED(x)` tells the C++ compiler not to warn. Ruby has no equivalent
    # and needs none: dropping it leaves the parameter unused, and rubocop's
    # Lint/UnusedMethodArgument renames it to `_x`, which is the golden's form.
    DROPPED = (%w[Q_UNUSED] + FALLTHROUGH).freeze
    ::GoldenHarness::Emitter::DROPPED = DROPPED unless
      ::GoldenHarness::Emitter.const_defined?(:DROPPED, false)

    # A map whose `[]` default-constructs, which is what lets the C++
    # `entries[k].field = v` work on an absent key. A bare `{}` returns nil and
    # raises, so the block form is required rather than cosmetic.
    MAP_TYPES = /\A(map|unordered_map|QMap|QHash)\z/

    STRING_TYPES = %w[QString QByteArray QLatin1String].freeze

    # A type that is a VIEW of what it is given, not a container of its own.
    # `QStringView bname(path)` does not copy `path`, it reads it -- and a Ruby
    # string needs no view, so the declaration is an alias.
    #
    # Declarations only. `names.contains(QStringView{i->localName()})` keeps
    # its wrapper in the golden, because there the view is an argument and not
    # a name being bound.
    VIEW_TYPES = %w[QStringView QByteArrayView QLatin1StringView].freeze

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
        # A log statement duplicates its MESSAGE instead; see log_body.
        return nil if log_statement?(node)

        found = first_ternary(node)
        return nil if found.nil?

        @ternary_branch[found.start_byte] = :consequence
        consequence = emit_stmt(node)
        @ternary_branch[found.start_byte] = :alternative
        alternative = emit_stmt(node)
        @ternary_branch.delete(found.start_byte)

        [If(expr(@cst.field(found, :condition)), Body(consequence), Body(alternative))]
      end

      def log_statement?(node)
        return false unless node.kind == "expression_statement"

        inner = @cst.named(node).first
        return false if inner.nil? || !log_chain?(inner)

        # Unless its ternary is between two strings, which log_body declines
        # so that the statement is duplicated instead.
        found = ternary_operand(inner)
        found.nil? || !string_ternary?(found)
      end

      # The first ternary this statement owns. One inside a nested lambda
      # belongs to that lambda's own statements and is lifted there instead.
      # A statement of its own, which `stmt` reaches through the body it is in.
      #
      # `first_ternary` must not look past one: the ternary in
      # owncloudpropagator's `std::remove_if` lambda is in the condition of an
      # `if` INSIDE a range-for, and searching through the loop lifted it to
      # the loop -- which copied the whole loop into both branches of a
      # condition that belongs inside it.
      NESTED = %w[
        compound_statement if_statement while_statement do_statement
        for_statement for_range_loop switch_statement case_statement
        labeled_statement lambda_expression
      ].freeze

      def first_ternary(node)
        return nil if node.kind == "lambda_expression"

        @cst.named(node).each do |kid|
          next if NESTED.include?(kid.kind)

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
        when "attributed_statement" then attributed(node)
        when "expression_statement" then expression_statement(node)
        when "return_statement" then [return_statement(node)]
        when "continue_statement" then [Next_()]
        when "break_statement" then [Break_()]
        when "if_statement" then [if_statement(node)]
        when "while_statement" then while_statement(node)
        when "do_statement" then [do_while(node)]
        when "for_range_loop" then [for_range(node)]
        when "for_statement" then counted_for(node)
        when "switch_statement" then [switch(node)]
        when "labeled_statement" then statements_of(node)
        else [expr(node)].compact
        end
      end

      # `[[fallthrough]];` carries nothing into Ruby -- a `when` that falls
      # through is written as one `when` with several values, which `switch`
      # below does by treating the label's body as empty. Any other attributed
      # statement contributes its statement.
      def attributed(node)
        return [] if fallthrough?(node)

        @cst.named(node).reject { _1.kind == "attribute_declaration" }.flat_map { stmt(_1) }
      end

      def fallthrough?(node)
        # `Q_FALLTHROUGH();` -- a call, where `[[fallthrough]];` is an
        # attribute. Both say the same thing and neither carries into Ruby.
        if node.kind == "expression_statement"
          call = @cst.dig(node, "call_expression")
          name = call && @cst.field(call, :function)
          return !name.nil? && name.kind == "identifier" &&
                 FALLTHROUGH.include?(@cst.text(name))
        end
        return false unless node.kind == "attributed_statement"

        @cst.descendants(node).any? do |inner|
          inner.kind == "identifier" && @cst.text(inner) == "fallthrough"
        end
      end

      # A type declared inside a body is still a type: it becomes a constant on
      # the class, so it is hoisted out and nothing is emitted in its place.
      def hoist(node)
        hoist_into(@class_name, struct(node)) if @cst.field(node, :body) && @cst.field(node, :name)
        []
      end

      # A declaration is a local assignment, except when it declares a type.
      def declaration(node)
        type = @cst.field(node, :type)
        if type && %w[struct_specifier class_specifier].include?(type.kind)
          hoist_into(@class_name, struct(type)) if @cst.field(type, :body)
          return []
        end

        # A map declared with no initialiser needs Ruby's default-block form,
        # because `QMap<K, V>::operator[]` default-constructs a missing value.
        # One declared WITH an initialiser is just that value, and treating
        # `const QMap<QString, Status> errorPaths = subJob->errorPaths();` as
        # the empty form dropped the call.
        return [map_declaration(node)] if map_type(node) && !initialised?(node)

        type = declaration_type(node)

        vexing = vexing_parse(node, type)
        return vexing if vexing

        init = @cst.child(node, "init_declarator", field: :declarator)
        return bare_declaration(node) if init.nil?

        # `for (auto i = c.begin(), last = c.end(); ...)` declares TWO names in
        # one declaration, and reading only the first dropped `last` -- which
        # the loop condition then referred to without ever binding it.
        extra = @cst.named(node).select { _1.kind == "init_declarator" && _1.start_byte != init.start_byte }
        return ([init] + extra).flat_map { one_declaration(node, _1, type) } unless extra.empty?

        one_declaration(node, init, type)
      end

      def one_declaration(node, init, type)
        name = @cst.dig(init, "identifier")
        return [] if name.nil?

        local = @cst.text(name).sub(/\A_/, "")

        # A constant cannot be assigned inside a method in Ruby, so it is
        # hoisted to the class the way a struct is. 02_prepare.py turns an
        # ALL_CAPS `#define` into one of these.
        if @cst.text(name).match?(/\A[A-Z][A-Z0-9_]*\z/)
          value = @cst.field(init, :value)
          # The parens a `#define` body is written with group nothing once it
          # is an assignment, and the golden drops them.
          value = @cst.named(value).first if value.kind == "parenthesized_expression"
          hoist_into(@class_name, Constant(@cst.text(name), expr(value)))
          return []
        end

        # `SqlQuery query(db);` -- a constructor, which the C++ spells like a
        # declaration with an argument list rather than with an `=`.
        arguments = @cst.child(init, "argument_list")
        if arguments && constructible?(type)
          values = @cst.named(arguments).filter_map { expr(_1) }
          # `QByteArray sql("SELECT ...")` -- a Qt string built from a literal
          # is just the literal; there is no Qt string type in Ruby. Same
          # reasoning as the QStringLiteral wrappers.
          return [Local(local_name(@cst.text(name)), values.first)] if
            values.one? && aliased?(@cst.text(type))

          return [Local(local_name(@cst.text(name)), Call(ConstPath(@cst.text(type)), :new, *values))]
        end

        if arguments
          # `bool re(_definition.ignoreHiddenFiles)` -- a primitive with a
          # constructor's shape constructs nothing.
          values = @cst.named(arguments).filter_map { expr(_1) }
          return [Local(local_name(@cst.text(name)), values.first)] if values.one?
        end

        assign(local_name(@cst.text(name)), @cst.field(init, :value))
      end

      def declaration_type(node) = @cst.field(node, :type)

      # A type whose one-argument construction carries nothing into Ruby: a Qt
      # string built from a string, or a view onto one.
      def aliased?(name) = STRING_TYPES.include?(name) || VIEW_TYPES.include?(name)

      def constructible?(type)
        return false unless type.kind == "type_identifier"
        return false unless @cst.text(type).match?(/\A[A-Z]/)

        !@facts.enum_type?(@cst.text(type))
      end

      # The single value such a declaration is initialised with.
      def scalar_declaration(node)
        declarator = @cst.child(node, "function_declarator", field: :declarator)
        return nil if declarator.nil?

        name = @cst.dig(declarator, "identifier", field: :declarator)
        values = @cst.named(@cst.field(declarator, :parameters))
        return nil if name.nil? || values.size != 1

        [Local(local_name(@cst.text(name)), fragment(@cst.text(values.first)))]
      end

      # C++'s most vexing parse. `SqlQuery pragma1(_db);` is a CONSTRUCTOR, but
      # it is spelled exactly like a function declaration and tree-sitter reads
      # it as one: a function_declarator whose `parameter_list` holds `_db` as
      # a parameter of type `_db`.
      #
      # A class type at statement level settles it -- nobody declares a
      # function returning a Qt class inside a method body -- so the parameters
      # are read back as the arguments they are.
      def vexing_parse(node, type)
        return nil if type.nil?
        # `bool re(_definition.ignoreHiddenFiles);` and `LogStatus
        # status(LogStatusRename);` have a constructor's shape over a type that
        # constructs nothing -- a primitive, or an enum. The declaration is
        # just its value.
        return scalar_declaration(node) unless constructible?(type)

        declarator = @cst.child(node, "function_declarator", field: :declarator)
        return nil if declarator.nil?

        name = @cst.dig(declarator, "identifier", field: :declarator)
        return nil if name.nil?

        values = @cst.named(@cst.field(declarator, :parameters)).map { fragment(@cst.text(_1)) }
        # `QStringView bname(path)` reaches here rather than the branch below,
        # because an argument that is a bare NAME makes the whole declaration
        # read as a function declarator.
        return [Local(local_name(@cst.text(name)), values.first)] if
          values.one? && aliased?(@cst.text(type))

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

      def initialised?(node)
        init = @cst.child(node, "init_declarator", field: :declarator)
        !init.nil? && !@cst.field(init, :value).nil?
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
        # `bool ok;` is `ok = false`, not `ok = nil`: the golden passes it to
        # `getSelectiveSyncList(..., ok)` as an out-parameter and then tests it.
        when "bool" then False_()
        # The last segment only. The oracle gives a type its full name --
        # `OCC::SyncJournalDb::DownloadInfo` -- and the golden writes the
        # nested type as the surrounding class already sees it.
        when %r{\Aobject:(.+)\z} then Call(Const(::Regexp.last_match(1).split("::").last), :new)
        else fallback_empty_value(node)
        end
      end

      # No fact for this name, so the syntax decides: a PascalCase type is a
      # class and gets constructed, anything else has no value yet.
      def fallback_empty_value(node)
        type = @cst.field(node, :type)
        return Nil_() unless type && type.kind == "type_identifier"
        return Nil_() unless @cst.text(type).match?(/\A[A-Z]/)
        return Nil_() if @facts.enum_type?(@cst.text(type))

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

        # A postfix `++` nested in this statement runs after it. `update` puts
        # the increment here rather than in the expression, and it is emitted
        # on the following line.
        return [expr(inner)].compact if inner.kind == "update_expression"

        deferred = []
        before = []
        # Saved and RESTORED, not cleared: a statement inside a lambda body is
        # emitted while the enclosing statement is still being built, and
        # clearing these threw the outer statement's own hoists away.
        outer = [@current_statement, @pending_updates, @pending_before]
        @current_statement = node
        @pending_updates = deferred
        @pending_before = before
        built = expression_statement_body(node, inner)
        @current_statement, @pending_updates, @pending_before = outer

        before + built + deferred
      end

      def expression_statement_body(node, inner)

        if (call = @cst.dig(inner, "call_expression"))
          name = @cst.field(call, :function)
          if name && name.kind == "identifier"
            text = @cst.text(name)
            return [Unless(assert_condition(call), Raise())] if ASSERTIONS.include?(text)
            return [Raise()] if UNREACHABLE.include?(text)
            return [] if DROPPED.include?(text)
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
        # `return (a && b);` -- the parens group nothing, and the golden drops
        # them. MultilineCondition does the same for an `if`, but only there.
        value = @cst.named(value).first if value.kind == "parenthesized_expression"

        Return(expr(value))
      end

      def if_statement(node)
        # `if (const auto r = f(x); r.isValid())` -- C++17's if-with-initialiser.
        # The declaration is hoisted above the `if`, which is where the golden
        # puts it; Ruby has no form that scopes it to the branch.
        #
        # 03_simplify.yml's s-if-init-hoist aims at this but looks for the
        # declaration under the clause's `value` field, and it is under an
        # `init_statement` instead, so it never fired.
        clause = @cst.field(node, :condition)
        init = clause && @cst.child(clause, "init_statement")
        prefix = init ? @cst.named(init).flat_map { stmt(_1) }.compact : []

        prefix + [if_statement_body(node)]
      end

      def if_statement_body(node)
        alternative = @cst.field(node, :alternative)
        else_body =
          if alternative
            inner = @cst.named(alternative).first
            Body(stmt(inner))
          end
        If(test(node), Body(statements_of(@cst.field(node, :consequence))), else_body)
      end

      # `do { ... } while (cond);` -- the body runs before the test, which is
      # what `loop do` with the test at the BOTTOM says:
      #
      #   loop do
      #     ...
      #     unless index > 0
      #       break
      #     end
      #   end
      #
      # Emitting `loop do ... end` and dropping the condition, which is what
      # this did before, is an infinite loop.
      def do_while(node)
        body = statements_of(@cst.field(node, :body))
        Loop(Body(body + [Unless(test(node), Break_())]))
      end

      # `while ((index = p.lastIndexOf('/')) != -1)`.
      #
      # Ruby allows the assignment in the condition, but the golden lowers it
      # the way the C++ reads: bind it once before the loop, test the variable,
      # and bind it again as the last thing the body does. The value is read
      # twice per iteration either way.
      def while_statement(node)
        clause = @cst.field(node, :condition)
        inner = clause && @cst.named(clause).reject { _1.kind == "init_statement" }.first
        found = inner && @cst.dig(inner, "assignment_expression")
        body = statements_of(@cst.field(node, :body))
        return [While(test(node), Body(body))] if found.nil?

        hoisted = expr(found)
        @condition_targets << found.start_byte
        test = expr(inner)
        @condition_targets.delete(found.start_byte)

        [hoisted, While(test, Body(body + [hoisted]))]
      end

      def condition(node)
        clause = @cst.field(node, :condition)
        # Past an init_statement, which if_statement has already hoisted out.
        inner = @cst.named(clause).reject { _1.kind == "init_statement" }.first
        inner ? expr(inner) : Nil_()
      end

      # A BRANCH's condition, where an integer is tested for being non-zero.
      #
      # `if (_blocked)` in C++ means `_blocked != 0`. Ruby has no falsy zero, so
      # written as a bare `if @blocked` the branch is taken for 0 as well --
      # `JobQueue#retry` queued the job instead of retrying it whenever the
      # queue was NOT blocked, and `enqueue` queued instead of refusing.
      # `negate` has always done the mirror of this for `!x`; the positive test
      # was simply never converted.
      #
      # Not `condition`, which a `switch` subject also uses: `case x != 0` is
      # not what a switch over an integer means.
      def test(node)
        clause = @cst.field(node, :condition)
        inner = @cst.named(clause).reject { _1.kind == "init_statement" }.first
        return Nil_() if inner.nil?
        return Binary(expr(inner), :!=, Int(0)) if integer?(inner)

        expr(inner)
      end

      # `for (auto &e : coll)` -> `coll.each do |e|`.
      def for_range(node)
        collection = expr(@cst.field(node, :right))
        CallBlock(Call(collection, :each), range_names(node),
                  Body(statements_of(@cst.field(node, :body))))
      end

      # `for (const auto &[path, error] : ...)` destructures, and so does a
      # block parameter list -- `each do |path, error|`, which is what the
      # golden has. Reading one `identifier` found only `path` and dropped the
      # second name.
      def range_names(node)
        bound = @cst.child(node, "structured_binding_declarator", field: :declarator)
        return @cst.named(bound).map { @cst.text(_1) } if bound

        [@cst.text(@cst.dig(node, "identifier", field: :declarator))]
      end

      # `for (int i = 0; i < n; ++i)` -> `(0...n).each do |i|`.
      #
      # The one counted-loop shape that has a Ruby equivalent keeping the
      # induction variable visible. Anything else lowers to `loop do` with the
      # init and step left in the body, which is what it did before.
      def counted_for(node)
        stmts = statements_of(@cst.field(node, :body))
        range = for_range_of(node)
        return counted_while(node, stmts) if range.nil?

        name, limit = range
        # `.each` only when the body leaves the counter alone. csync_exclude's
        # escape loop does `++i` again inside the body to skip an escaped pair,
        # and a block parameter cannot carry that.
        return counted_while(node, stmts) if assigns?(@cst.field(node, :body), name)

        [CallBlock(Call(Paren(ExclusiveRange(Int(0), limit)), :each), [name], Body(stmts))]
      end

      # The counted loop written out, for every `for` that `.each` cannot
      # express: one with no initialiser (`for (; j < len; ++j)`), one counting
      # from somewhere other than zero, one whose body moves the counter
      # itself. The initialiser goes before the loop and the update at the end
      # of its body, which is the `while` form the goldens have.
      #
      # `continue` inside such a body skips the update, where C++ would have
      # run it. The goldens are written this way regardless, so the shape is
      # theirs; `_csync_excluded_common` has no `continue` in one.
      def counted_while(node, stmts)
        test = @cst.field(node, :condition)
        return [Loop(Body(stmts))] if test.nil?

        initializer = @cst.child(node, "declaration", field: :initializer)
        advance = @cst.field(node, :update)
        before = initializer ? declaration(initializer) : []
        after = advance ? [expr(advance)].compact : []
        before + [While(expr(test), Body(stmts + after))]
      end

      # Whether this block assigns the name -- by `=`, `+=`, `++` or `--`.
      def assigns?(body, name)
        return false if body.nil?

        @cst.descendants(body).any? do |node|
          next false unless %w[assignment_expression update_expression].include?(node.kind)

          target = @cst.field(node, node.kind == "update_expression" ? :argument : :left)
          target && @cst.text(target) == name
        end
      end

      def for_range_of(node)
        initializer = @cst.child(node, "declaration", field: :initializer)
        condition = @cst.field(node, :condition)
        update = @cst.field(node, :update)
        return nil if initializer.nil? || condition.nil? || update.nil?
        return nil unless condition.kind == "binary_expression"
        return nil unless @cst.text(@cst.field(condition, :operator)) == "<"

        name = @cst.dig(initializer, "identifier", field: :declarator)
        start = @cst.dig(initializer, "number_literal")
        return nil if name.nil? || start.nil? || @cst.text(start) != "0"
        return nil unless @cst.text(@cst.field(condition, :left)) == @cst.text(name)

        limit = expr(@cst.field(condition, :right))
        # `.each` reads the limit ONCE; the C++ `for` re-reads it on every
        # iteration. That only makes no difference when the limit cannot change
        # under the loop, so a member is excluded -- which is exactly where the
        # two goldens part company over the same C++ shape:
        #
        #   for (int i = 0; i < segments.size(); ++i)        -> (0...).each
        #   for (int i = 0; i < _runningJobs.count(); ++i)   -> while
        #
        # `segments` is a local built just above its loop. `_runningJobs` is a
        # member, and the second loop's own body calls `possiblyRunNextJob`,
        # which can add to it.
        return nil if mentions_ivar?(limit)

        [@cst.text(name), limit]
      end

      def mentions_ivar?(node)
        return false unless node.is_a?(::Parser::AST::Node)
        return true if node.type == :ivar

        node.children.any? { mentions_ivar?(_1) }
      end

      # A block's statements, ignoring those that carry no meaning in Ruby.
      def effective(body)
        @cst.named(body).reject { fallthrough?(_1) }
      end

      # A case arm's statements, with a `break` in the MIDDLE of the arm folded
      # away. `label_of` removes the one that ends an arm, which has
      # no counterpart in a `when`; one in the middle is doing real work -- it
      # skips the rest of the arm -- and Ruby has nothing that does that:
      #
      #   if (j == len) {              if j == len
      #       regex.append("\\[");       regex.append("\\[")
      #       break;                   else
      #   }                     ->       bracket_expr = ...
      #   bracketExpr = ...;             regex.append(bracket_expr)
      #   regex.append(bracketExpr);   end
      #
      # Leaving the `break` in would be worse than redundant: the switch sits
      # inside a `while`, so Ruby would break the LOOP.
      def arm(nodes)
        at = nodes.index { breaking_if?(_1) }
        return nodes.flat_map { stmt(_1) }.compact if at.nil? || at == nodes.size - 1

        guard = nodes[at]
        taken = @cst.named(@cst.field(guard, :consequence))
                    .reject { _1.kind == "break_statement" }
                    .flat_map { stmt(_1) }.compact
        nodes[0...at].flat_map { stmt(_1) }.compact +
          [If(test(guard), Body(taken), Body(arm(nodes[(at + 1)..])))]
      end

      # An `if` with no `else` whose body ends with the switch's own `break`.
      def breaking_if?(node)
        return false unless node.kind == "if_statement"
        return false unless @cst.field(node, :alternative).nil?

        consequence = @cst.field(node, :consequence)
        return false unless consequence&.kind == "compound_statement"

        @cst.named(consequence).last&.kind == "break_statement"
      end

      # A C++ `switch` is a Ruby `case`. 03_simplify.yml has already braced
      # every body, so each label has exactly one block under it.
      def switch(node)
        labels = @cst.named(@cst.field(node, :body))
                     .select { _1.kind == "case_statement" }
                     .map { label_of(_1) }
        whens = []
        else_body = nil
        pending = []

        labels.each_with_index do |(value, nodes, closes), index|
          # A label with nothing under it shares the next one's body: in C++ it
          # falls through, so the faithful Ruby is one `when` with both values.
          # A label whose body is nothing but `[[fallthrough]];` says the same
          # thing out loud.
          #
          # `closes` is what separates that from a label whose body was nothing
          # BUT a `break` -- a deliberate no-op that stops. The golden gives
          # that one its own `when ... / nil`.
          if nodes.empty? && !closes && value
            pending << value
            next
          end

          # `default: break;` is a C++ formality -- a switch over an enum needs
          # one to be exhaustive -- and the golden writes no `else` for it.
          next if nodes.empty? && value.nil?

          # The continuation joins the arm's own statements BEFORE `arm` folds,
          # so a `break` that ends the arm is seen to have statements after it.
          # `:no_status` guards with `if (...) { break; }` and then falls
          # through; folded, that is `unless (...)` around the shared body,
          # where emitting the arm alone left a bare `break` with no loop to
          # leave.
          body =
            if nodes.empty?
              Nil_()
            else
              Body(arm(nodes + continuation(labels, index, closes)))
            end
          if value
            whens << When(pending + [value], body)
          else
            # `default:` closes the run rather than absorbing it. The values
            # that fell through this far behave exactly as the default does,
            # but Ruby needs at least one `when`, and the golden gives them one
            # with an empty body:
            #
            #   when :success, :restoration, :conflict
            #     nil
            #   else
            whens << When(pending, Nil_()) if pending.any?
            else_body = body
          end
          pending = []
        end

        # A run still open at the end of the switch is its own `when` too.
        whens << When(pending, Nil_()) if pending.any?

        Case(subject(node), whens, else_body)
      end

      def subject(node) = condition(node)

      # One case label, as `[value, statements, closes?]`.
      #
      # The trailing `break` is dropped HERE rather than by a rule, because
      # whether it was there is the only thing separating an arm that falls
      # through from an arm that deliberately does nothing.
      def label_of(label)
        value = @cst.field(label, :value)
        body = @cst.child(label, "compound_statement")
        nodes = body ? @cst.named(body).reject { _1.kind == "comment" || fallthrough?(_1) } : []
        closes = !nodes.empty? && terminates?(nodes.last)
        nodes = nodes[0..-2] if nodes.last&.kind == "break_statement"
        [value && expr(value), nodes, closes]
      end

      # C++ runs ON into the arms below one that does not end in `break` or
      # `return`. Ruby's `when` does not, so those arms are repeated here:
      # `CSYNC_INSTRUCTION_NEW` returns a job when the item is a directory and
      # otherwise goes on to do exactly what `CSYNC_INSTRUCTION_SYNC` does, and
      # that is how the golden has it, written out in both arms.
      #
      # The arms' own NODES, not their emitted statements, so that the caller
      # can hand the whole run to `arm` at once -- a `break` ending one arm has
      # to see the next arm's statements to fold against.
      def continuation(labels, index, closes)
        out = []
        until closes || (index += 1) >= labels.size
          _value, nodes, closes = labels[index]
          out.concat(nodes)
        end
        out
      end

      # Whether control can reach the end of this statement. An arm ending in
      # an `if`/`else` whose both branches return cannot fall through, which is
      # why `CSYNC_INSTRUCTION_REMOVE` is not given the arms below it.
      def terminates?(node)
        case node&.kind
        when "break_statement", "return_statement", "continue_statement",
             "goto_statement", "throw_statement"
          true
        when "compound_statement"
          terminates?(@cst.named(node).last)
        when "if_statement"
          alternative = @cst.field(node, :alternative)
          return false if alternative.nil?

          terminates?(@cst.field(node, :consequence)) &&
            terminates?(@cst.named(alternative).first)
        when "expression_statement"
          # `Q_UNREACHABLE()` is `[[noreturn]]`, and becomes `raise`. Without
          # this, discovery's `case CSYNC_NOT_EXCLUDED: Q_UNREACHABLE();` read
          # as falling through and collected the arm below it.
          call = @cst.dig(node, "call_expression")
          name = call && @cst.field(call, :function)
          !name.nil? && name.kind == "identifier" && UNREACHABLE.include?(@cst.text(name))
        else
          false
        end
      end
  end
end

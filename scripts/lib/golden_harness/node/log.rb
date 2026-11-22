# frozen_string_literal: true

module GoldenHarness
  class Emitter
    # `qCInfo(lcDb)` and `qWarning(lcDb)` alike: the second is Qt's
    # un-categorised logger being passed a category anyway, which is a slip in
    # the source but still a log statement.
    LOG_CALL = /\Aq[C]?(Info|Debug|Warning|Critical|Fatal)\z/

    # Qt names two levels differently from Ruby's logger.
    LOG_LEVEL = { "Warning" => "warn", "Critical" => "error" }.freeze

    private

      # `qCInfo(lcDisco) << u"X" << a` -- a QDebug stream, not an expression.
      def log_chain?(node)
        return false unless node.kind == "binary_expression"

        !log_head(node).nil?
      end

      # The `qCInfo(lcDisco)` at the far left of the chain.
      def log_head(node)
        at = node
        while at && at.kind == "binary_expression"
          return nil unless @cst.text(@cst.field(at, :operator)) == "<<"

          at = @cst.field(at, :left)
        end
        return nil unless at && at.kind == "call_expression"

        # `qCInfo(lcDisco).nospace() << ...` -- the leftmost call is
        # `.nospace()`, whose own argument list is empty, so the qC* call has to
        # be found inside it or the category comes out blank.
        qc_call(at)
      end

      def qc_call(node)
        fn = @cst.field(node, :function)
        return node if fn && fn.kind == "identifier" && LOG_CALL.match?(@cst.text(fn))
        return nil if fn.nil?

        inner = @cst.dig(fn, "call_expression")
        inner && qc_call(inner)
      end

      # `Log.info("sync.discovery") { "X #{a}" }`.
      #
      # The message is one interpolated string. QDebug writes a space between
      # the operands it is handed, so the renderings are joined with one -- and
      # that is the whole of the layout decision, because where the author
      # broke the C++ chain is not something an AST can hold. The printer lays
      # the result out.
      def log(node)
        head = log_head(node)
        call = Call(Const(:Log), log_level(head), Str(log_category(head)))
        CallBlock(call, [], log_body(node))
      end

      # A ternary among the operands duplicates the MESSAGE, not the statement:
      # the golden keeps one `Log.info(...)` whose block body is an `if`, with
      # a whole message in each branch. Statement-level duplication is right
      # for a call argument and wrong here, so the lift happens at this level.
      def log_body(node)
        found = ternary_operand(node)
        return message(node) if found.nil? || string_ternary?(found)

        @ternary_branch[found.start_byte] = :consequence
        consequence = message(node)
        @ternary_branch[found.start_byte] = :alternative
        alternative = message(node)
        @ternary_branch.delete(found.start_byte)

        If(expr(@cst.field(found, :condition)), consequence, alternative)
      end

      # A ternary choosing between two STRING LITERALS contributes text to the
      # message rather than a value, and the golden duplicates the whole
      # statement for it -- `commit_internal` gets two `Log.debug` calls --
      # where a ternary choosing between two VALUES is duplicated inside the
      # block. The branches say which.
      def string_ternary?(found)
        %w[string_literal raw_string_literal concatenated_string].include?(
          @cst.field(found, :consequence).kind
        )
      end

      def ternary_operand(node)
        operands(node).drop(1).each do |operand|
          found = @cst.dig(operand, "conditional_expression")
          return found if found && !@ternary_branch.key?(found.start_byte)
        end
        nil
      end

      # The message, grouped the way the C++ author laid the chain out.
      #
      # One Ruby string literal per source line, which Ruby concatenates --
      # `parser` keeps them as nested `dstr` nodes, so the grouping survives
      # into the AST rather than being lost to layout. Transpile/MultilineString
      # puts the breaks back in.
      def message(node)
        groups = []
        line = nil
        operands(node).drop(1).each do |operand|
          at = @cst.line(operand)
          fresh = line.nil? || at != line
          groups << [] if fresh
          # QDebug writes a space between the operands it is handed, so one is
          # inserted between them -- but NOT across a line break, where the
          # literal the author wrote already starts with its own space. The
          # golden's continuation reads `" | valid: "`, with one space, not two.
          groups.last << Str(" ") unless fresh
          groups.last << part(operand)
          line = at
        end

        parts = groups.reject(&:empty?).map { Dstr(merge(_1)) }
        return Str("") if parts.empty?
        return parts.first if parts.one?

        Dstr(parts)
      end

      def log_level(head)
        fn = @cst.text(@cst.dig(head, "identifier", field: :function))
        suffix = LOG_CALL.match(fn)[1]
        LOG_LEVEL.fetch(suffix, suffix.downcase)
      end

      def log_category(head)
        arg = @cst.named(@cst.field(head, :arguments)).first
        return "" if arg.nil?

        # `qCWarning(lcEngine())` names the category through its accessor, so
        # the parens are part of the argument's text and the lookup missed --
        # the category came out as the literal string `lcEngine()`.
        text = @cst.text(arg).sub(/\(\s*\)\z/, "")
        @facts.category(text) || text
      end

      # The chain flattened left to right.
      def operands(node)
        return [node] unless node.kind == "binary_expression" &&
                             @cst.text(@cst.field(node, :operator)) == "<<"

        operands(@cst.field(node, :left)) + [@cst.field(node, :right)]
      end

      # A literal contributes its text; anything else is interpolated.
      def part(node)
        inner = node.kind == "parenthesized_expression" ? @cst.named(node).first : node
        inner = @cst.field(inner, @ternary_branch[inner.start_byte]) if
          inner.kind == "conditional_expression" && @ternary_branch.key?(inner.start_byte)
        # A literal contributes its TEXT, wherever it came from -- including
        # from a ternary branch, which is a string in
        # `<< (startTrans ? "and starting new transaction" : "")`. Interpolating
        # it instead gives `#{"and starting new transaction"}`.
        return Str(string_value(inner)) if %w[string_literal raw_string_literal].include?(inner.kind)

        Interp(expr(inner))
      end

      # Adjacent literals fold together, so the message has one `str` per run
      # of text rather than one per operand.
      def merge(parts)
        parts.each_with_object([]) do |node, out|
          if node.type == :str && out.last&.type == :str
            out[-1] = Str(out.last.children.first + node.children.first)
          else
            out << node
          end
        end
      end
  end
end

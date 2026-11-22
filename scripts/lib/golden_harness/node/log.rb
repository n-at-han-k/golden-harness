# frozen_string_literal: true

module GoldenHarness
  class Emitter
    LOG_CALL = /\AqC(Info|Debug|Warning|Critical|Fatal)\z/

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
        level = log_level(head)
        category = log_category(head)
        message = Dstr(merge(operands(node).drop(1).flat_map { [Str(" "), part(_1)] }.drop(1)))
        CallBlock(Call(Const(:Log), level, Str(category)), [], message)
      end

      def log_level(head)
        fn = @cst.text(@cst.dig(head, "identifier", field: :function))
        suffix = LOG_CALL.match(fn)[1]
        LOG_LEVEL.fetch(suffix, suffix.downcase)
      end

      def log_category(head)
        arg = @cst.named(@cst.field(head, :arguments)).first
        return "" if arg.nil?

        text = @cst.text(arg)
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
        return Str(string_value(node)) if %w[string_literal raw_string_literal].include?(node.kind)

        inner = node.kind == "parenthesized_expression" ? @cst.named(node).first : node
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

# frozen_string_literal: true

module RuboCop
  module Cop
    module Transpile
      # Layout for a transliterated `if` condition. Two related rules:
      #
      # 1. A long boolean condition is wrapped in parentheses, one operand per
      #    line:
      #
      #      # bad
      #      if !a.check(x) && (y == z || !a.check(w))
      #
      #      # good
      #      if (
      #        !a.check(x) &&
      #        y == z ||
      #        !a.check(w)
      #      )
      #
      # 2. A long `if` line that is NOT wrapped gets a blank line before its
      #    body, so the body does not begin immediately after 190 characters of
      #    arguments.
      #
      # Neither is covered by a built-in. RuboCop's Layout cops re-indent
      # existing line breaks but never introduce them, and
      # `Layout/EmptyLineAfterMultilineCondition` applies only to a condition
      # that already spans lines.
      #
      # Both are layout decisions about valid Ruby, which is why they are cops
      # rather than ast-grep fix templates. Operand order and grouping come
      # from the C++ and are not touched -- only where the breaks fall.
      class MultilineCondition < Base
        extend AutoCorrector
        include RangeHelp

        MSG = 'Wrap a long condition in parentheses, one operand per line.'
        MSG_BODY_GAP = 'Separate a long `if` line from its body with a blank line.'

        # Wrap a boolean condition past this width. Shorter ones read better
        # inline, and the golden keeps them that way.
        MIN_WIDTH = 80

        # An unwrapped first line past this width gets a blank before the body.
        LONG_FIRST_LINE = 120

        def on_if(node)
          return if node.ternary? || node.modifier_form?

          wrap_condition(node)
          gap_before_body(node)
        end

        private

        # Rule 1 applies: a single-line boolean condition long enough to wrap.
        def wrappable?(condition)
          !condition.nil? && !condition.multiline? &&
            condition.source.length >= MIN_WIDTH && boolean?(condition)
        end

        def wrap_condition(node)
          condition = node.condition
          return unless wrappable?(condition)

          add_offense(condition) do |corrector|
            corrector.replace(condition, rewritten(node, condition))
          end
        end

        def gap_before_body(node)
          return unless node.source_range.source_line.length >= LONG_FIRST_LINE
          return if node.condition.nil? || node.condition.multiline?
          # Rule 1 is about to wrap this condition. Both rules see the SAME
          # source, before either correction is applied, so without this guard
          # the condition got wrapped AND gained a blank line before the body --
          # the one thing the golden does not do after a wrapped condition.
          return if wrappable?(node.condition)

          body = node.if_branch
          return if body.nil?
          return if blank_line?(node.source_range.first_line + 1)

          add_offense(body.source_range.begin, message: MSG_BODY_GAP) do |corrector|
            corrector.insert_before(range_by_whole_lines(body.source_range), "\n")
          end
        end

        def blank_line?(lineno)
          line = processed_source.lines[lineno - 1]
          line.nil? || line.strip.empty?
        end

        def boolean?(node)
          inner = unwrap(node)
          inner.and_type? || inner.or_type?
        end

        # A parenthesised sub-expression arrives as a `begin` node wrapping the
        # real operator, so an unwrapped check treated `(b || c)` as a single
        # opaque operand and stopped flattening there.
        def unwrap(node)
          node.begin_type? && node.children.one? ? unwrap(node.children.first) : node
        end

        # Flatten a nested and/or chain into its operands, left to right, so
        # `a && (b || c)` yields [a, '&&', b, '||', c].
        def operands(node, out = [])
          inner = unwrap(node)
          if inner.and_type? || inner.or_type?
            operands(inner.lhs, out)
            out << inner.operator.to_s
            operands(inner.rhs, out)
          else
            out << inner.source
          end
          out
        end

        def rewritten(node, condition)
          indent = node.source_range.source_line[/\A[ \t]*/]
          lines = operands(condition).each_slice(2).map do |operand, operator|
            "#{indent}  #{operand}#{operator ? " #{operator}" : ''}"
          end
          "(\n#{lines.join("\n")}\n#{indent})"
        end
      end
    end
  end
end

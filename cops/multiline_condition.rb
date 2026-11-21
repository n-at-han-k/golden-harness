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
        MSG_REDUNDANT = 'Drop the parentheses around a single-line condition.'

        # Wrap a boolean condition past this width.
        #
        # The golden is not consistent about where the line falls -- it leaves a
        # 72-character chain inline and wraps a 68-character one -- so the
        # threshold is a decision this cop makes, not one read off the file. It
        # runs over the golden as well as the generated output, so whatever it
        # picks, both sides get the same treatment.
        MIN_WIDTH = 60

        # An unwrapped first line past this width gets a blank before the body.
        LONG_FIRST_LINE = 120

        def on_if(node)
          return if node.ternary? || node.modifier_form?

          drop_redundant_parens(node)
          wrap_condition(node)
          gap_before_body(node)
        end

        def on_while(node)
          drop_redundant_parens(node)
        end
        alias on_until on_while

        private

        # Rule 3: `if (a == b)` -> `if a == b`.
        #
        # The parens are an artefact of the C++ condition_clause. The golden is
        # inconsistent about them by hand -- 41 single-line conditions keep them
        # and 109 do not, with no pattern, because they are wherever the C++
        # happened to put them -- so a cop settles it uniformly over BOTH sides
        # rather than the rules guessing.
        #
        # Only a SINGLE-LINE condition. The wrapped multi-line form is rule 1's
        # output and its parens are what make it parse:
        #
        #     if (
        #       a &&
        #       b
        #     )
        #
        # which is also why the built-in Style/RedundantParentheses cannot be
        # used here -- it unwraps that form and fights rule 1 forever.
        def drop_redundant_parens(node)
          condition = node.condition
          return if condition.nil? || condition.multiline?
          return unless condition.begin_type? && condition.children.one?

          add_offense(condition, message: MSG_REDUNDANT) do |corrector|
            corrector.replace(condition, condition.children.first.source)
          end
        end

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

        # Split a top-level and/or chain into its operands, left to right.
        #
        # It does NOT descend through parentheses. The C++ author's grouping is
        # information -- `a && (b || c) && (d || e)` says which tests belong
        # together -- and the golden keeps it:
        #
        #     if (
        #       @query_server == :parent_not_changed &&
        #       db_entry.is_valid &&
        #       (
        #         db_entry.type == :item_type_virtual_file_download ||
        #         local_entry.type == :item_type_virtual_file_download
        #       ) &&
        #       ...
        #     )
        #
        # Flattening it threw that away and emitted one flat operand list, so
        # `unwrap` is used only to SEE the operator for the boolean? test, never
        # to split past a paren.
        def operands(node, out = [])
          if node.and_type? || node.or_type?
            operands(node.lhs, out)
            out << node.operator.to_s
            operands(node.rhs, out)
          else
            out << node
          end
          out
        end

        def rewritten(node, condition)
          indent = node.source_range.source_line[/\A[ \t]*/]
          "(\n#{render(unwrap(condition), "#{indent}  ")}\n#{indent})"
        end

        # One operand per line at `indent`. A parenthesised operand that is
        # itself a boolean chain is laid out the same way, one level deeper,
        # which is what reproduces the golden's nesting.
        def render(node, indent)
          operands(node).each_slice(2).map do |operand, operator|
            tail = operator ? " #{operator}" : ""
            inner = unwrap(operand)
            if operand.begin_type? && (inner.and_type? || inner.or_type?)
              "#{indent}(\n#{render(inner, "#{indent}  ")}\n#{indent})#{tail}"
            else
              "#{indent}#{operand.source.gsub(/\s*\n\s*/, ' ')}#{tail}"
            end
          end.join("\n")
        end
      end
    end
  end
end

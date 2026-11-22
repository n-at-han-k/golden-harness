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

        # An inner parenthesised group inside a CONDITION is expanded only
        # once its inline form reaches this width. Measured over every such
        # group in the golden: the nine expanded ones are 61, 61, 107, 107,
        # 114, 117, 120, 121 and 135 characters, and the single inline one is
        # 45, so anything in 46..60 separates them. An assignment value never
        # expands its groups (60, 64 and 65, all inline), which is what
        # `expand_inner` carries.
        NEST_WIDTH = 50

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
          wrap_condition(node)
        end
        alias on_until on_while

        # Rule 4: the same layout for a long boolean ASSIGNMENT, which the
        # golden wraps exactly as it wraps a condition:
        #
        #     no_server_entry = (
        #       (@query_server != :parent_not_changed && !server_entry.is_valid) ||
        #       (@query_server == :parent_not_changed && !db_entry.is_valid)
        #     )
        # `return a && b && c` past the width, wrapped the same way an
        # assignment is -- the golden writes the `operator==` bodies that way.
        def on_return(node)
          value = node.children.first
          return if value.nil?

          wrap_value(node, value)
        end

        def on_lvasgn(node)
          drop_value_parens(node, node.expression)
          wrap_value(node, node.expression)
        end
        alias on_ivasgn on_lvasgn
        alias on_cvasgn on_lvasgn
        alias on_gvasgn on_lvasgn

        # `item.type = ...` is a send, not an assignment node; its value is the
        # single argument.
        def on_send(node)
          return unless node.assignment_method?
          return unless node.arguments.one?

          wrap_value(node, node.arguments.first)
        end

        private

        # The same for an assigned value: `x = (a == b)` -> `x = a == b`.
        #
        # Only a SHORT one. A long parenthesised value is what rule 4 wraps,
        # and its parens are what make the wrapped form parse -- the golden has
        # `@metadata_table_is_empty = get_file_record_count == 0` without them
        # and `modified_on_server = (item.instruction & (...))` with them, and
        # width is what separates the two.
        def drop_value_parens(node, value)
          return if value.nil? || value.multiline?
          return unless value.begin_type? && value.children.one?
          return if value.source.length >= MIN_WIDTH

          add_offense(value, message: MSG_REDUNDANT) do |corrector|
            corrector.replace(value, value.children.first.source)
          end
        end

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

        # Rule 1 applies: a boolean condition that is not already laid out.
        #
        # A condition the C++ had already broken across lines counts too. It
        # arrives multiline but in the C++'s shape -- operator at the end of the
        # line, operand on the next -- and the old `!multiline?` test skipped
        # it, so `if job.http_status_code == 207 ||` stayed as the source left
        # it. Canonical form is a parenthesised condition spanning lines, which
        # makes this idempotent.
        def wrappable?(condition)
          return false if condition.nil? || !boolean?(condition)
          return false if canonical?(condition)

          condition.multiline? || condition.source.length >= MIN_WIDTH ||
            grouped?(condition)
        end

        # A condition with a parenthesised boolean sub-group in it, which the
        # golden wraps however short the whole thing is:
        #
        #   if (
        #     major == 1 &&
        #     minor == 8 &&
        #     (
        #       patch == 0 ||
        #       patch == 1
        #     )
        #   )
        #
        # 53 columns, and wrapped; a 58-column chain with no group beside it is
        # left inline. The author's grouping is information, and once it is
        # worth writing down it is worth seeing.
        def grouped?(condition)
          operands(unwrap(condition)).any? do |operand|
            next false unless operand.respond_to?(:begin_type?) && operand.begin_type?

            inner = unwrap(operand)
            inner.and_type? || inner.or_type?
          end
        end

        # Already in the form rule 1 produces.
        def canonical?(condition)
          condition.begin_type? && condition.multiline?
        end

        # The canonical form is compared EXACTLY, not merely recognised by
        # shape. `canonical?` only asks whether the condition is parenthesised
        # and spans lines, and that is true of a condition the C++ had already
        # broken -- so one arriving as
        #
        #     if (compute_local_checksum(...)
        #         && item.checksum_header == db_entry.checksum_header)
        #
        # was wrapped once, kept the source's deeper continuation indent on the
        # second operand, and then counted as canonical forever after. Nothing
        # in rubocop normalises that: Layout/MultilineOperationIndentation does
        # not reach inside a parenthesised condition, so both indents are
        # accepted and whichever the generator emitted is what survived.
        #
        # Rendering the target and replacing only on a mismatch is idempotent by
        # construction -- `rewritten` is a function of the operands and the
        # node's indent, so one correction reaches a fixed point.
        def wrap_condition(node)
          condition = node.condition
          return if condition.nil? || !boolean?(condition)
          return if pending_infix?(condition)
          return unless wrappable?(condition) || canonical?(condition)

          # Whether the GROUP is why this wrapped. A short condition wraps only
          # because it holds a parenthesised boolean, so that group is the point
          # and it opens out whatever its width:
          #
          #   if (                        if (
          #     major == 1 &&               job.http_status_code == 404 ||
          #     minor == 8 &&               (job.etag != base.etag && !item.is_directory) ||
          #     (                           @discovery_data.is_renamed(original_path)
          #       patch == 0 ||           )
          #       patch == 1
          #     )
          #   )
          #
          # 53 columns flat on the left and the 26-column group expanded; 124
          # on the right and the 45-column group left alone. Width alone cannot
          # separate those -- it would have to expand the smaller and keep the
          # larger -- but which rule did the wrapping can.
          target = rewritten(node, condition, force_nested: flat(condition).length < MIN_WIDTH)
          return if condition.source == target

          add_offense(condition) do |corrector|
            corrector.replace(condition, target)
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

        def wrap_value(node, value)
          # A long parenthesised value counts even when its operator is not
          # boolean. `modified_on_server = (item.instruction & (A | B | C | D))`
          # is bitwise, so `boolean?` rejects it, but the golden still puts the
          # content on its own line -- and the renderer already produces that
          # shape for a single operand.
          unless wrappable?(value)
            return unless value&.begin_type? && !value.multiline? &&
                          value.source.length >= MIN_WIDTH

          end

          add_offense(value) do |corrector|
            corrector.replace(value, rewritten(node, value, expand_inner: false))
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

        def rewritten(node, condition, expand_inner: true, force_nested: false)
          indent = node.source_range.source_line[/\A[ \t]*/]
          inner = render(unwrap(condition), "#{indent}  ",
                         expand_inner: expand_inner, force_nested: force_nested)
          "(\n#{inner}\n#{indent})"
        end

        # The condition on one line, so a measurement of it does not change
        # once this cop has wrapped it.
        #
        # The spaces just inside a paren are squeezed out as well. Without
        # that, flattening `(\n  patch == 0 ||\n  patch == 1\n)` left
        # `( patch == 0 || patch == 1 )` -- four columns wider than the source
        # ever was -- which pushed a 58-column condition over the 60 limit on
        # alternate passes, so the cop expanded the group, collapsed it,
        # expanded it again, and rubocop stopped on whichever came last.
        # A condition `Transpile/InfixOperator` has yet to rewrite. Its width is
        # not final, and `len.-(1)` is a character wider than `len - 1`.
        def pending_infix?(condition)
          condition.each_node(:send).any? { InfixOperator.pending?(_1) }
        end

        def flat(node)
          node.source.gsub(/\s*\n\s*/, " ").gsub(/\(\s+/, "(").gsub(/\s+\)/, ")")
        end

        # One operand per line at `indent`. A parenthesised operand that is
        # itself a boolean chain is laid out the same way, one level deeper,
        # which is what reproduces the golden's nesting.
        # An operand's source with the parentheses removed when they wrap a
        # single operand and so group nothing: the golden writes
        # `local_entry.is_directory`, not `(local_entry.is_directory)`.
        def unparenthesise(operand)
          source = operand.source.gsub(/\s*\n\s*/, " ")
          return source unless operand.begin_type? && operand.children.one?

          inner = operand.children.first
          return source if inner.and_type? || inner.or_type?

          inner.source.gsub(/\s*\n\s*/, " ")
        end

        # The boolean chain inside `!( ... )`, or nil if the operand is not that.
        def negated_group(operand)
          return nil unless operand.send_type? && operand.method?(:!)

          receiver = operand.receiver
          return nil unless receiver&.begin_type?

          inner = unwrap(receiver)
          (inner.and_type? || inner.or_type?) ? inner : nil
        end

        # `expand_inner` decides whether a parenthesised sub-group is itself
        # broken up. The golden expands one inside a CONDITION (6 of its 7
        # wrapped conditions) and keeps one inline inside an ASSIGNMENT value
        # -- `no_server_entry = ((a && b) || (c && d))` stays two lines -- so
        # the caller passes what it is.
        def render(node, indent, expand_inner: true, force_nested: false)
          operands(node).each_slice(2).map do |operand, operator|
            tail = operator ? " #{operator}" : ""
            inner = unwrap(operand)
            if expand_inner && operand.begin_type? &&
               (inner.and_type? || inner.or_type?) &&
               (force_nested || flat(operand).length >= NEST_WIDTH)
              # Every level opens out, not just the first. The golden
              # contradicts itself here -- the same shape
              # `X && ((a && b) || (c && d))` is expanded at one site and left
              # inline at another -- and measured over the whole file,
              # expanding throughout agrees with it on ten more lines.
              nested = render(inner, "#{indent}  ", expand_inner: expand_inner)
              "#{indent}(\n#{nested}\n#{indent})#{tail}"
            elsif expand_inner && (negated = negated_group(operand))
              # `!(a && b && c)` -- the `!` stays on the opening paren and the
              # group inside is laid out like any other. Treating the whole
              # negation as one opaque operand left it on a single long line
              # where the golden breaks it up.
              nested = render(negated, "#{indent}  ", expand_inner: expand_inner)
              "#{indent}!(\n#{nested}\n#{indent})#{tail}"
            else
              "#{indent}#{unparenthesise(operand)}#{tail}"
            end
          end.join("\n")
        end
      end
    end
  end
end

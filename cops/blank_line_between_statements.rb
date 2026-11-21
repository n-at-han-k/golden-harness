# frozen_string_literal: true

module RuboCop
  module Cop
    module Transpile
      # Separates a multi-line statement from its siblings with a blank line.
      #
      #   # bad
      #   if a
      #     b
      #   end
      #   c = 1
      #
      #   # good
      #   if a
      #     b
      #   end
      #
      #   c = 1
      #
      # No built-in cop does this. Checked against `rubocop --show-cops`:
      # EmptyLineAfterGuardClause covers only guard clauses,
      # EmptyLineAfterMultilineCondition only the gap between a wrapped
      # condition and its body, and the EmptyLinesAround*Body family only the
      # inside of a body. Nothing enforces separation BETWEEN sibling
      # statements, which is the whole of the golden's remaining spacing.
      class BlankLineBetweenStatements < Base
        extend AutoCorrector
        include RangeHelp

        MSG_ADD = 'Separate a multi-line statement from the next with a blank line.'
        MSG_REMOVE = 'Do not separate two single-line statements with a blank line.'

        # `require "x"` / `require_relative "x"`.
        def_node_matcher :require?, <<~PATTERN
          (send nil? {:require :require_relative} ...)
        PATTERN

        def on_begin(node)
          node.children.each_cons(2) do |current, following|
            # Requires carry the #include grouping over from the C++, where the
            # blank lines are the author's grouping rather than layout. Left
            # alone in both directions.
            next if require?(current) || require?(following)

            # The rule, read off the golden: a blank line separates statements
            # when either side spans lines, or when the next one is
            # return/next/break. Two single-line statements are NOT separated --
            # and a blank between them is removed, because a C++ blank survives
            # the comment deletion that used to follow it.
            #
            # Spacing BEFORE a def belongs to Layout/EmptyLineBetweenDefs, with
            # exactly one exception: a struct hoisted out of a method body is
            # emitted directly above that method's def, and the golden keeps the
            # two adjacent:
            #
            #     Entries = Struct.new(
            #       ...
            #     )
            #     def process
            #
            # Claiming every def, rather than just that case, made this cop
            # delete the blank line EmptyLineBetweenDefs had just inserted, so
            # `rubocop -A` never converged and every method in the file ended up
            # jammed against the one before it.
            if following.def_type?
              next unless current.casgn_type?

              wanted = false
            else
              wanted = current.multiline? || following.multiline? ||
                       flow_control?(following)
            end
            present = blank_line?(current.source_range.last_line + 1)
            next if wanted == present

            if wanted
              add_offense(following.source_range.begin, message: MSG_ADD) do |corrector|
                corrector.insert_after(
                  range_by_whole_lines(current.source_range, include_final_newline: true),
                  "\n"
                )
              end
            else
              add_offense(following.source_range.begin, message: MSG_REMOVE) do |corrector|
                corrector.remove(blank_range(current.source_range.last_line + 1))
              end
            end
          end
        end
        alias on_kwbegin on_begin

        private

        # The whole of a blank line, newline included.
        def blank_range(lineno)
          range = processed_source.buffer.line_range(lineno)
          range_by_whole_lines(range, include_final_newline: true)
        end

        def flow_control?(node)
          node.return_type? || node.next_type? || node.break_type?
        end

        # processed_source.lines is 0-based, so line N is at index N-1.
        def blank_line?(lineno)
          line = processed_source.lines[lineno - 1]
          line.nil? || line.strip.empty?
        end
      end
    end
  end
end

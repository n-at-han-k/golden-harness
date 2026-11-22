# frozen_string_literal: true

module RuboCop
  module Cop
    module Transpile
      # One line per adjacent string literal, joined by a backslash.
      #
      #   # bad
      #   query.prepare("CREATE TABLE x(" "a INTEGER," "b TEXT" ");")
      #
      #   # good
      #   query.prepare(
      #     "CREATE TABLE x(" \
      #     "a INTEGER," \
      #     "b TEXT" \
      #     ");"
      #   )
      #
      # The grouping is the C++ author's: each literal is one line of the
      # statement it came from -- a `qCInfo(...) << ... << ...` chain, or an
      # adjacent-literal SQL string -- and the emitter keeps them as separate
      # literals so that the grouping survives into the AST. Ruby concatenates
      # them, and `parser` represents the pair as nested `dstr` nodes rather
      # than as one string.
      #
      # Unparser writes them all on one line, which is valid and loses nothing
      # but the author's grouping. Restoring the breaks is layout, so it is a
      # cop, like every other spacing decision here.
      #
      # Only a node whose children are ALL literals is touched. A plain
      # interpolated string has `begin` children among its `str` ones, and a
      # lone literal is a `str` node rather than a `dstr`, so this shape only
      # arises from adjacency.
      class MultilineString < Base
        extend AutoCorrector

        MSG = 'Put each adjacent string literal on its own line.'

        INDENT = 2

        ASSIGNED = %i[lvasgn ivasgn cvasgn gvasgn casgn op_asgn or_asgn and_asgn].freeze

        def on_dstr(node)
          parts = node.children
          return if parts.size < 2
          return unless parts.all? { _1.type == :dstr || _1.type == :str }

          if sole_argument?(node) && node.parent.single_line?
            wrap_call(node, parts)
          elsif aligned?(node)
            wrap_aligned(node, parts)
          else
            wrap_body(node, parts)
          end
        end

        private

          # The string is a call's only argument, so the CALL opens out too and
          # the literals line up under one another, one level in. Done here
          # rather than left to SingleLineArguments, which declines to touch an
          # argument that already spans lines -- and this one does, by the time
          # it would be asked.
          def wrap_call(node, parts)
            send_node = node.parent
            return if send_node.loc.begin.nil? || send_node.loc.end.nil?

            base = send_node.source_range.source_line[/\A[ \t]*/]
            inner = base + (' ' * INDENT)
            body = parts.map(&:source).join(" \\\n#{inner}")
            rewrite(send_node.loc.begin.join(send_node.loc.end), "(\n#{inner}#{body}\n#{base})")
          end

          # Under the first literal, which is where the golden puts a
          # continuation whose string is an assigned value or an argument:
          #
          #   sql = "SELECT ... " \
          #         "FROM blacklist WHERE path=?1"
          #
          # The column is the node's own, not the line's indentation -- the
          # `sql = ` in front of it is what the alignment is measured past.
          def wrap_aligned(node, parts)
            base = " " * node.source_range.column
            rewrite(node.source_range, parts.map(&:source).join(" \\\n#{base}"))
          end

          # An assigned value, a call argument or a returned value aligns; a
          # block body does not.
          #
          # `return` belongs with the first group because
          # `Layout/LineEndStringConcatenationIndentation` aligns it under the
          # opening quote, and a cop here that indented it two columns instead
          # would be undone on the next round -- the pair oscillate, rubocop
          # gives up, and nothing else in the file gets corrected either.
          def aligned?(node)
            parent = node.parent
            return false if parent.nil?
            return true if ASSIGNED.include?(parent.type) || parent.type == :return
            return false unless parent.send_type?

            parent.assignment_method? || parent.arguments.any? { _1.equal?(node) }
          end

          # Anywhere else -- a block body, an `if` branch -- the first literal
          # stays where it is and the rest come two columns further in.
          def wrap_body(node, parts)
            base = node.source_range.source_line[/\A[ \t]*/] + (' ' * INDENT)
            head, *rest = parts.map(&:source)
            rewrite(node.source_range, ([head] + rest.map { "#{base}#{_1}" }).join(" \\\n"))
          end

          def rewrite(range, target)
            return if range.source == target

            add_offense(range, message: MSG) do |corrector|
              corrector.replace(range, target)
            end
          end

          def sole_argument?(node)
            parent = node.parent
            return false if parent.nil? || !parent.send_type?

            parent.arguments.size == 1 && parent.arguments.first.equal?(node)
          end
      end
    end
  end
end

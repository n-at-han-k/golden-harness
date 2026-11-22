# frozen_string_literal: true

module RuboCop
  module Cop
    module Transpile
      # One line per adjacent string literal, joined by a backslash.
      #
      #   # bad
      #   "Processing  #{path}" " | valid:  #{ok}" " | mtime:  #{at}"
      #
      #   # good
      #   "Processing  #{path}" \
      #     " | valid:  #{ok}" \
      #     " | mtime:  #{at}"
      #
      # The grouping is the C++ author's: each literal is one line of the
      # `qCInfo(...) << ... << ...` chain it came from, and the emitter keeps
      # them as separate adjacent literals so that it survives into the AST --
      # Ruby concatenates them, and `parser` represents the pair as nested
      # `dstr` nodes rather than as one string.
      #
      # Unparser writes them all on one line, which is valid and loses nothing
      # but the author's grouping. Restoring the breaks is layout, so it is a
      # cop, like every other spacing decision here.
      #
      # Only a node whose children are ALL literals is touched. An ordinary
      # interpolated string has `begin` children among its `str` ones and is
      # left alone; this shape only arises from adjacency.
      class MultilineString < Base
        extend AutoCorrector

        MSG = 'Put each adjacent string literal on its own line.'

        # The continuation indent, measured off the golden: two columns past
        # the first literal, not aligned with it.
        INDENT = 2

        def on_dstr(node)
          parts = node.children
          return if parts.size < 2
          return unless parts.all? { _1.type == :dstr || _1.type == :str }
          return unless parts.any? { _1.type == :dstr }

          base = node.source_range.source_line[/\A[ \t]*/]
          head, *rest = parts.map(&:source)
          target = ([head] + rest.map { "#{base}#{" " * INDENT}#{_1}" }).join(" \\\n")
          return if node.source == target

          add_offense(node) do |corrector|
            corrector.replace(node, target)
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

module RuboCop
  module Cop
    module Transpile
      # Lays `Struct.new` out one member per line.
      #
      #   # bad
      #   Entries = Struct.new(:db_entry, :server_entry, keyword_init: true)
      #
      #   # good
      #   Entries = Struct.new(
      #     :db_entry,
      #     :server_entry,
      #     keyword_init: true
      #   )
      #
      # This belongs in a cop rather than in the ast-grep fix template. By the
      # time rubocop runs the file is valid Ruby, so a cop can work on it --
      # unlike the constant hoist, which could not be a cop because
      # `dynamic constant assignment` is a Lint/Syntax error and rubocop never
      # builds an AST for such a file at all.
      #
      # Keeping it here also keeps the layout decision with the other layout
      # decisions, instead of hard-coding newlines into a fix template that is
      # otherwise about structure.
      class MultilineStructNew < Base
        extend AutoCorrector
        include RangeHelp

        MSG = 'Lay out Struct.new with one member per line.'

        # Matches `Struct.new(...)` with at least one argument.
        # @!method struct_new(node)
        def_node_matcher :struct_new, <<~PATTERN
          (send (const {nil? cbase} :Struct) :new $...)
        PATTERN

        def on_send(node)
          args = struct_new(node)
          return if args.nil? || args.empty?
          # Already multi-line: leave it to the Layout cops.
          return if node.multiline?

          add_offense(node) do |corrector|
            corrector.replace(node, rewritten(node, args))
          end
        end

        private

        def rewritten(node, args)
          # Indent from the LINE, not from the `Struct.new` column. Using the
          # send's own column aligned the members under the opening paren
          # (column 11 for `Entries = Struct.new(`), where the golden indents
          # them two spaces from the assignment.
          indent = node.source_range.source_line[/\A[ \t]*/]
          inner = args.map { |arg| "#{indent}  #{arg.source}" }.join(",\n")
          "Struct.new(\n#{inner}\n#{indent})"
        end
      end
    end
  end
end

# frozen_string_literal: true

module RuboCop
  module Cop
    module Transpile
      # `do ... end` for a block that spans lines, braces for one inside a
      # CONDITION.
      #
      #   # bad
      #   coll.each { |e|
      #     f(e)
      #   }
      #
      #   # good
      #   coll.each do |e|
      #     f(e)
      #   end
      #
      # Unparser writes every block with braces, which is correct Ruby and the
      # golden's own choice in a condition:
      #
      #   if !db.list_files_in_path(path) { |rec|
      #     ...
      #   }
      #
      # but not anywhere else. The two forms parse to the SAME tree -- measured
      # on `if !a.list(x) { |rec| f(rec) }` against the `do ... end` spelling,
      # the ASTs compare equal -- so this is a layout choice and belongs in a
      # cop, not in the emitter.
      #
      # `Style/BlockDelimiters` cannot be used for it: its `line_count_based`
      # style rewrites the condition case too, and the golden keeps braces
      # there. Same division of labour as SingleLineArguments, which also
      # leaves a condition to MultilineCondition.
      class BlockDelimiters < Base
        extend AutoCorrector

        MSG = 'Use `do ... end` for a multi-line block.'

        def on_block(node)
          return unless node.multiline?
          return unless node.braces?
          return if inside_condition?(node)

          add_offense(node) do |corrector|
            corrector.replace(node.loc.begin, 'do')
            corrector.replace(node.loc.end, 'end')
          end
        end

        private

          # A block sitting in an `if`/`while`/`until` condition keeps its
          # braces, which is what the golden writes.
          def inside_condition?(node)
            node.each_ancestor(:if, :while, :until).any? do |ancestor|
              condition = ancestor.condition
              next false if condition.nil?

              condition.source_range.begin_pos <= node.source_range.begin_pos &&
                node.source_range.end_pos <= condition.source_range.end_pos
            end
          end
      end
    end
  end
end

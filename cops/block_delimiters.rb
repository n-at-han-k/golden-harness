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

        MSG = 'Use `do ... end` for a block run for its effect.'

        ASSIGNMENTS = %i[lvasgn ivasgn cvasgn gvasgn casgn op_asgn or_asgn and_asgn
                         masgn indexasgn].freeze

        CONTROL_FLOW = %i[while until for case_match].freeze

        # What a block can evaluate TO. A literal is a value; so is an `if`
        # whose every branch is one.
        LITERALS = %i[str dstr sym int float true false nil].freeze

        def on_block(node)
          return unless node.multiline?
          return unless node.braces?
          return if inside_condition?(node)
          return if value_block?(node)

          add_offense(node) do |corrector|
            corrector.replace(node.loc.begin, 'do')
            corrector.replace(node.loc.end, 'end')
          end
        end

        private

          # A block whose whole purpose is the value it evaluates to keeps its
          # braces however many lines it spans. The golden writes
          #
          #   Log.info("sync.discovery") {
          #     if server_entry.is_directory
          #       "..."
          #     else
          #       "..."
          #     end
          #   }
          #
          # with braces, and the `.each`/`Hash.new` blocks beside it with
          # `do ... end`. Line count does not separate those; what the block is
          # FOR does, and it is the same test SingleLineBlock applies.
          def value_block?(node)
            return false unless node.arguments.empty?
          return false unless braced_call?(node)

            body = node.body
            return false if body.nil? || body.begin_type?
            return false if ASSIGNMENTS.include?(body.type)
          return false if CONTROL_FLOW.include?(body.type)
          # A lone `if` is one node, but whether it is a VALUE depends on its
          # branches. The golden writes
          #
          #   Log.info("sync.discovery") {        connect(..., context) do
          #     if server_entry.is_directory        if ...capabilities...
          #       "Processing ..."                    fetch_private_link_url(...)
          #     else                               else
          #       "Processing ..."                   context.delete_later
          #     end                                end
          #   }                                   end
          #
          # with braces on the left and `do ... end` on the right. Both bodies
          # are a single `if`; what differs is that one evaluates to a string
          # and the other runs statements.
          return false if branching?(body) && !value_branches?(body)
            return false if body.send_type? && body.assignment_method?

            true
          end

          # Which CALLS take a brace block.
          #
          # Read off the goldens: `lambda { ... }` and `Log.info(...) { ... }`
          # keep braces, and every other block -- `connect(...)`, `.each`,
          # `Hash.new` -- is written `do ... end`. The body alone does not
          # separate them: `connect(..., context) do ... end` and
          # `Log.info(...) { if ... end }` both hold a single `if`.
          def braced_call?(node)
            send_node = node.send_node
            return true if send_node.method?(:lambda) && send_node.receiver.nil?

            receiver = send_node.receiver
            !receiver.nil? && receiver.const_type? && receiver.short_name == :Log
          end

          def branching?(node) = %i[if case].include?(node.type)

          # Every branch of the `if`/`case` evaluates to a literal.
          def value_branches?(node)
            branches = node.type == :if ? node.children[1..] : node.children[1..]
            branches.compact.all? do |branch|
              next value_branches?(branch) if branching?(branch)
              next branch.children.last && LITERALS.include?(branch.children.last.type) if branch.type == :when

              LITERALS.include?(branch.type)
            end
          end

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

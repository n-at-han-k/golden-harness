# frozen_string_literal: true

module RuboCop
  module Cop
    module Transpile
      # Join a block that only produces a VALUE back onto one line.
      #
      #   # bad
      #   Log.info("sync.discovery") {
      #     "STARTING #{@current_folder.server}"
      #   }
      #
      #   # good
      #   Log.info("sync.discovery") { "STARTING #{@current_folder.server}" }
      #
      # Unparser lays every block out across lines; the golden keeps this one
      # inline. The discriminator is read off the golden and is not width: a
      # `Hash.new do |hash, key| hash[key] = Entries.new end` fits easily in 120
      # columns and is still written open, while the Log block above is inlined
      # at 118.
      #
      # What separates them is what the block is FOR. A log message block takes
      # no parameters and its body is one expression. A loop or an initialiser
      # block takes parameters and runs statements for their effect.
      #
      # Width is not part of it, and nor is which call it is: the golden inlines
      # `QTimer.single_shot(10, this) { ... }` and a 131-column `Log.info`
      # block alike, and leaves `connect(...) do ... end` open because its body
      # is several statements. A body that already spans lines is left alone,
      # which is what keeps the `Log.info { if ... end }` block open.
      #
      # Deliberately NO width limit. The golden inlines this block at 131
      # columns, and `Layout/LineLength` is disabled in this project precisely
      # because a transliterated line is as long as its source makes it. Width
      # is not what decides the question.
      class SingleLineBlock < Base
        extend AutoCorrector

        MSG = 'Keep a value-producing block on one line.'

        ASSIGNMENTS = %i[lvasgn ivasgn cvasgn gvasgn casgn op_asgn or_asgn and_asgn
                         masgn indexasgn].freeze

        CONTROL_FLOW = %i[while until for case_match].freeze

        # What a block can evaluate TO. A literal is a value; so is an `if`
        # whose every branch is one.
        LITERALS = %i[str dstr sym int float true false nil].freeze

        def on_block(node)
          return unless node.multiline?
          return unless node.arguments.empty?

          body = node.body
          return if body.nil? || body.begin_type? || body.multiline?
          return if ASSIGNMENTS.include?(body.type)
          return if CONTROL_FLOW.include?(body.type)
          # A lone `if` is a value only when its branches are; see
          # BlockDelimiters for the two shapes this separates.
          return if branching?(body) && !value_branches?(body)
          return if assignment_send?(body)

          target = "#{node.send_node.source} { #{body.source} }"

          add_offense(node) do |corrector|
            corrector.replace(node, target)
          end
        end

        private

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

          # `a.b = c` is a send, not an assignment node.
          def assignment_send?(body) = body.send_type? && body.assignment_method?
      end
    end
  end
end

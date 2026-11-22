# frozen_string_literal: true

module RuboCop
  module Cop
    module Transpile
      # Write an arithmetic operator infix inside a comparison.
      #
      #   # bad
      #   conflict_paths.size > r.num_new.+(r.num_old)
      #
      #   # good
      #   conflict_paths.size > r.num_new + r.num_old
      #
      # Unparser emits the dot form for a binary send nested inside another
      # one, because in general re-associating it would change the meaning --
      # `a - b.-(c)` is not `a - b - c`. It is safe in exactly the case the
      # transliteration keeps producing, though: arithmetic inside a COMPARISON,
      # where the arithmetic binds tighter and the grouping cannot change.
      #
      # So the rewrite is limited to that, rather than undoing unparser's
      # caution everywhere.
      class InfixOperator < Base
        extend AutoCorrector

        MSG = 'Write %<operator>s infix.'

        ARITHMETIC = %i[+ - * / %].freeze
        COMPARISON = %i[> < >= <= == != <=>].freeze

        # Whether this cop is going to rewrite `node`.
        #
        # `Transpile/MultilineCondition` asks, because the dot form is one
        # character wider than the infix form and measuring it pushed a
        # 59-column condition over the wrap limit. rubocop's `-A` loops until
        # nothing corrects, so a condition holding one of these is measured on
        # the next round instead.
        def self.pending?(node)
          return false unless node.send_type?
          return false unless ARITHMETIC.include?(node.method_name)
          return false if node.loc.dot.nil?
          return false unless node.arguments.one?

          parent = node.parent
          !parent.nil? && parent.send_type? && COMPARISON.include?(parent.method_name)
        end

        def on_send(node)
          return unless self.class.pending?(node)

          target = "#{node.receiver.source} #{node.method_name} #{node.arguments.first.source}"
          add_offense(node, message: format(MSG, operator: node.method_name)) do |corrector|
            corrector.replace(node, target)
          end
        end
      end
    end
  end
end

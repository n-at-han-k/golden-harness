# frozen_string_literal: true

module RuboCop
  module Cop
    module Transpile
      # Give an assigned array its brackets.
      #
      #   # bad
      #   WIN_SYSTEM_FILES = "$Recycle.Bin", "System Volume Information"
      #
      #   # good
      #   WIN_SYSTEM_FILES = ["$Recycle.Bin", "System Volume Information"]
      #
      # Ruby allows the bare form and parses it to the same array, so unparser
      # emits it for a multi-element array -- while writing a single-element one
      # as `["a"]`. The golden brackets both, and a list that looks like a list
      # is worth the two characters.
      class ArrayBrackets < Base
        extend AutoCorrector

        MSG = 'Bracket the array.'

        ASSIGNMENTS = %i[lvasgn ivasgn cvasgn gvasgn casgn].freeze

        def on_array(node)
          return unless node.loc.begin.nil?
          return if node.parent.nil?
          return unless ASSIGNMENTS.include?(node.parent.type)
          return unless node.parent.children.last.equal?(node)

          add_offense(node) do |corrector|
            corrector.replace(node, "[#{node.children.map(&:source).join(', ')}]")
          end
        end
      end
    end
  end
end

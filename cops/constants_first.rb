# frozen_string_literal: true

module RuboCop
  module Cop
    module Transpile
      # Moves a constant assignment above the first method in its class.
      #
      #   # bad
      #   class ProcessDirectoryJob
      #     def start
      #     end
      #
      #     Entries = Struct.new(
      #       :db_entry,
      #       keyword_init: true
      #     )
      #     def process
      #     end
      #
      #   # good
      #   class ProcessDirectoryJob
      #     Entries = Struct.new(
      #       :db_entry,
      #       keyword_init: true
      #     )
      #
      #     def start
      #     end
      #
      #     def process
      #     end
      #
      # `Layout/ClassStructure` states the order and reports the violation, but
      # does not correct this one: its autocorrect swaps a node with its
      # preceding sibling and it declines the move here, so the offence sat in
      # the file with nothing able to fix it.
      #
      # The constant arrives mid-class because transform.yml hoists a
      # `struct` out of the method body that declared it and emits it directly
      # above that method -- which is the right place to put it when all you
      # know is the method, and the wrong place once you can see the class.
      class ConstantsFirst < Base
        extend AutoCorrector
        include RangeHelp

        MSG = 'Move the constant above the first method in the class.'

        def on_class(node)
          body = node.body
          return if body.nil? || !body.begin_type?

          children = body.children
          first_def = children.index(&:def_type?)
          return if first_def.nil?

          children.each_with_index do |child, index|
            next unless index > first_def
            next unless child.casgn_type?

            move(child, children[first_def])
          end
        end
        alias on_module on_class

        private

        def move(constant, target)
          add_offense(constant) do |corrector|
            source = range_by_whole_lines(constant.source_range,
                                         include_final_newline: true)
            text = source.source
            corrector.remove(source)
            # A blank line after it, so it does not run into the method that
            # now follows; Layout/EmptyLines collapses any doubling.
            corrector.insert_before(
              range_by_whole_lines(target.source_range), "#{text}\n"
            )
          end
        end
      end
    end
  end
end

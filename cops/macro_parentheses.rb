# frozen_string_literal: true

module RuboCop
  module Cop
    module Transpile
      # Drop the parentheses from a module-inclusion or require call.
      #
      #   # bad
      #   include(FileSystem::SizeLiterals)
      #
      #   # good
      #   include FileSystem::SizeLiterals
      #
      # Unparser parenthesises every call that takes an argument, which is
      # right for an ordinary one and wrong for these: they read as
      # declarations, and both the golden and `.rubocop.yml`'s ClassStructure
      # treat them that way -- `module_inclusion` is its own category there.
      #
      # `Style/MethodCallWithArgsParentheses` cannot be used for it: its
      # `omit_parentheses` style would strip them from every call in the file.
      class MacroParentheses < Base
        extend AutoCorrector

        MSG = 'Call %<name>s without parentheses.'

        MACROS = %i[include extend prepend require require_relative].freeze

        def on_send(node)
          return unless MACROS.include?(node.method_name)
          return unless node.receiver.nil?
          return unless node.arguments.one?
          return if node.loc.begin.nil? || node.loc.end.nil?

          argument = node.arguments.first
          return if argument.multiline?

          add_offense(node, message: format(MSG, name: node.method_name)) do |corrector|
            corrector.replace(node.loc.begin.join(node.loc.end), " #{argument.source}")
          end
        end
      end
    end
  end
end

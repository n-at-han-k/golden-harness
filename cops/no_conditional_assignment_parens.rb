# frozen_string_literal: true

require "rubocop/nathank/no_conditional_assignment"

# Lets `Nathank/NoConditionalAssignment` see a parenthesised conditional.
#
# The cop tests the assigned value against a list of Prism conditional nodes:
#
#     CONDITIONALS = [CaseMatchNode, CaseNode, IfNode, UnlessNode]
#     def conditional?(rhs) = CONDITIONALS.any? { |k| rhs.is_a?(k) }
#
# but `perms = (if ... end)` parses as a `ParenthesesNode` wrapping a
# `StatementsNode` wrapping the `IfNode`, so the test failed and the offence
# went unreported -- and with it the correction that pushes the assignment
# inside each branch.
#
# The parentheses are an artefact of the transliteration: the C++ was a ternary,
# and the rules wrap one before expanding it.
module Transpile
  module NoConditionalAssignmentParens
    def check(node, rhs)
      super(node, unwrap_parentheses(rhs))
    end

    private

    # `(x)` holds its contents in a StatementsNode; a parenthesised conditional
    # is that with exactly one statement.
    def unwrap_parentheses(rhs)
      while rhs.is_a?(::Prism::ParenthesesNode) &&
            rhs.body.is_a?(::Prism::StatementsNode) &&
            rhs.body.body.size == 1
        rhs = rhs.body.body.first
      end
      rhs
    end
  end
end

RuboCop::Nathank::NoConditionalAssignment.prepend(
  Transpile::NoConditionalAssignmentParens
)

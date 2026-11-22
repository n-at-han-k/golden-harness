# frozen_string_literal: true

require "rubocop/cop/style/disable_syntax"

# Makes `Style/DisableSyntax`'s ternary offence autocorrectable.
#
# The cop already `extend AutoCorrector` and corrects the `unless` it bans, but
# its ternary branch adds the offence with no corrector block:
#
#     elsif node.ternary? && !ternary_allowed?
#       add_offense(node, message: "Do not use ternary operator.")
#     end
#
# so a banned ternary was reported with nothing able to fix it. This supplies
# the correction for that one branch and leaves every other syntax the cop
# bans to the cop itself.
#
# Prepended rather than reimplemented as a new cop: the rule is already stated
# in `.rubocop.yml` under `Style/DisableSyntax`, and a second cop saying the
# same thing in a different namespace would report every ternary twice.
module Transpile
  module DisableSyntaxTernaryAutocorrect
    # Node types that hold statements rather than take part in an expression.
    # Ascending stops at one of these: the node below it is the statement to
    # duplicate.
    CONTAINERS = %i[
      kwbegin def defs block numblock class module sclass
      case case_match when in_pattern resbody ensure rescue
    ].freeze

    def on_if(node)
      return super unless node.ternary? && !ternary_allowed?

      statement = enclosing_statement(node)
      return super if statement.nil?

      add_offense(node, message: "Do not use ternary operator.") do |corrector|
        corrector.replace(statement, expanded(statement, node))
      end
    end

    private

    # Where the ternary is not the whole right-hand side of an assignment there
    # is nowhere to put the `if`, so the enclosing STATEMENT is emitted once per
    # branch with the ternary replaced by that branch. That is what covers a
    # ternary used as a call argument, a hash value, or inside a string
    # interpolation.
    def expanded(statement, ternary)
      indent = statement.source_range.source_line[/\A[ \t]*/]
      [
        "if #{ternary.condition.source}",
        reindent(substituted(statement, ternary, ternary.if_branch), indent),
        "#{indent}else",
        reindent(substituted(statement, ternary, ternary.else_branch), indent),
        "#{indent}end"
      ].join("\n")
    end

    # The outermost node still inside one statement.
    def enclosing_statement(node)
      current = node
      loop do
        parent = current.parent
        return current if parent.nil?
        return current if CONTAINERS.include?(parent.type)
        return current if statement_sequence?(parent)
        # A conditional's own condition is part of the enclosing statement; its
        # branches are statements in their own right.
        if %i[if while until].include?(parent.type)
          return current unless parent.condition == current
        end

        current = parent
      end
    end

    # A `begin` node is a sequence of statements only when it holds more than
    # one. With a single child it is either a parenthesised expression --
    # `(a ? b : c)` -- or a string interpolation, since `"#{x}"` parses as
    # `(dstr (begin x))`. Treating those as containers stopped the ascent inside
    # the interpolation and produced
    #
    #     "#{if server_entry.is_directory ... end}"
    #
    # instead of duplicating the log statement around it.
    def statement_sequence?(node)
      node.begin_type? && node.children.size > 1
    end

    # The statement's source with the ternary's range replaced by one of its
    # branches. Both ranges come from the AST, so the cut is exact and nothing
    # else in the statement is reformatted.
    def substituted(statement, ternary, branch)
      base = statement.source_range
      from = ternary.source_range.begin_pos - base.begin_pos
      to = ternary.source_range.end_pos - base.begin_pos
      source = statement.source
      "#{source[0...from]}#{branch.source}#{source[to..]}"
    end

    # One level in, carrying any internal line breaks with it.
    def reindent(source, indent)
      source.lines.map { |line| "#{indent}  #{line.chomp}" }.join("\n")
    end
  end
end

RuboCop::Cop::Style::DisableSyntax.prepend(
  Transpile::DisableSyntaxTernaryAutocorrect
)

# frozen_string_literal: true

module RuboCop
  module Cop
    module Transpile
      # Joins a wrapped argument list back onto one line.
      #
      #   # bad
      #   handle_excluded(path.target, e.local_entry.name, is_hidden,
      #     e.server_entry.is_vault_file)
      #
      #   # good
      #   handle_excluded(path.target, e.local_entry.name, is_hidden, e.server_entry.is_vault_file)
      #
      # The line break is an artefact of the C++: the transliteration preserves
      # whatever no rewriter touched, so a call the source wrapped stays
      # wrapped. Ruby has no need of it and the golden keeps such calls on one
      # line.
      #
      # No built-in cop does this. `Layout/LineLength` is the only one that
      # moves code between lines and it only ever SPLITS; it is also disabled
      # here on purpose, since it would wrap transliterated expressions at
      # arbitrary points.
      #
      # A call with one argument per line is left alone -- that is the
      # deliberate layout MultilineStructNew produces, and joining it would
      # fight that cop forever.
      class SingleLineArguments < Base
        extend AutoCorrector

        MSG = 'Keep an argument list on one line.'
        MSG_SPLIT = 'Put one argument per line; the joined call is too long.'

        # How long the joined argument list may be.
        #
        # Measured off the golden's wrapped calls: it joins them at argument
        # lengths of 59 and 64 and puts one argument per line at 80 and 86, so
        # anything in 65..79 separates the two.
        #
        # The ARGUMENTS are measured, not the finished line. Cops run in the
        # same pass as the indentation cops, so the indentation a correction
        # sees is whatever the file happens to have at that moment -- a width
        # including it split a call that was comfortably inside the limit by
        # the time the file settled.
        ARGS_WIDTH = 72

        def on_send(node)
          args = node.arguments
          return if args.empty?
          # A trailing block is not part of the argument list.
          return if node.block_literal?
          if args.one?
            join_up(node, args.first)
            return
          end
          if args.first.source_range.line == args.last.source_range.last_line
            # Splitting applies only to a call ALREADY in the wrapped form --
            # one whose `(` ends its line. A call the source put on a single
            # line stays there however long it is, which is what the golden
            # does with the 190-column `handle_excluded(...)`.
            split(node, args) if wrapped?(node) && too_long?(node, args)
            return
          end
          return if one_per_line?(args)
          # A trailing block is not part of the argument list.
          return if node.block_literal?
          # Only the wrap BETWEEN arguments is a C++ artefact. An argument that
          # itself spans lines carries its own layout, and in Ruby a newline is
          # a statement separator -- flattening a `lambda { ... }` argument ran
          # its statements together into
          #   lambda { @pending_async_jobs -= 1 QTimer.single_shot(...) if ...
          # which destroyed two methods and stopped the file parsing.
          return if args.any?(&:multiline?)

          add_offense(node) do |corrector|
            corrector.replace(arguments_range(node), joined(args))
          end
        end
        alias on_csend on_send

        private

        # The call's `(` ends its line, so the arguments were already pushed
        # onto lines of their own.
        def wrapped?(node)
          return false if node.loc.begin.nil?

          node.loc.begin.source_line[node.loc.begin.column + 1..].strip.empty?
        end

        def too_long?(_node, args)
          joined(args).length >= ARGS_WIDTH
        end

        # A lone argument pushed onto its own line comes back up onto the call's.
        #
        #     # bad
        #     @discovery_data.fatal_error(
        #                     "Server replied ... %1: %2".arg(folder, msg)
        #                   )
        #
        #     # good
        #     @discovery_data.fatal_error("Server replied ... %1: %2".arg(folder, msg))
        #
        # Same artefact as the multi-argument case, and the only shape left that
        # nothing normalised. RuboCop will not touch it: measured with `--only
        # Layout/FirstArgumentIndentation,Layout/ArgumentAlignment,Layout/ClosingParenthesisIndentation`,
        # a 22-space-indented lone argument reports NO offence, so whatever
        # column the C++ happened to leave it in is what survived -- and
        # s-ternary-arg duplicates the statement per branch, so the same call
        # came out indented 15 in one branch and 28 in the other.
        #
        # `split` cannot do this: it replaces only the ARGUMENTS range, and for
        # one argument that range's replacement is the argument's own source, so
        # the leading whitespace is outside the edit and nothing moves.
        # Joining replaces the span BETWEEN the parentheses instead.
        #
        # An argument that is itself multi-line keeps its layout, for the same
        # reason the multi-argument path skips those: a newline inside it is a
        # statement separator, not decoration.
        def join_up(node, arg)
          return if node.loc.begin.nil? || node.loc.end.nil?
          return if arg.multiline?
          return if node.loc.begin.end_pos == arg.source_range.begin_pos &&
                    arg.source_range.end_pos == node.loc.end.begin_pos

          inner = node.loc.begin.end.join(node.loc.end.begin)
          add_offense(node) do |corrector|
            corrector.replace(inner, arg.source)
          end
        end

        # One argument per line, at one level in from the call.
        def split(node, args)
          indent = "#{node.source_range.source_line[/\A[ \t]*/]}  "
          add_offense(node, message: MSG_SPLIT) do |corrector|
            corrector.replace(arguments_range(node),
                              args.map(&:source).join(",\n#{indent}"))
          end
        end

        # Each argument starting on its own line is intentional layout.
        def one_per_line?(args)
          args.map { |a| a.source_range.line }.uniq.size == args.size
        end

        def arguments_range(node)
          node.arguments.first.source_range.join(node.arguments.last.source_range)
        end

        # Every argument is single-line by the time this runs, so there is no
        # newline inside one to collapse.
        def joined(args)
          args.map(&:source).join(", ")
        end
      end
    end
  end
end

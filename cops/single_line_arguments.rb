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

        def on_send(node)
          args = node.arguments
          return if args.size < 2
          # The ARGUMENTS have to span lines, not the call. A call whose args
          # all sit on one line between a wrapped `(` and `)` is already what
          # this cop wants: offending on it replaced the range with identical
          # text, so the offence was reported again on every run and
          # `rubocop -A` could never reach zero.
          return if args.first.source_range.line == args.last.source_range.last_line
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

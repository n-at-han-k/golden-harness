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

        # The column past which a call is laid out one argument per line.
        #
        # This is a DECISION, not a measurement. The golden cannot be fitted:
        # it splits calls whose one-line forms are 163, 130, 123 and 117
        # columns while keeping others inline at 186, 138 and 123, so the two
        # sets overlap and no threshold -- and no "did the C++ wrap it?" test,
        # which disagrees on two more sites -- separates them. Earlier versions
        # of this cop measured the ARGUMENT list instead and overlap there too
        # (74 split, 76 inline).
        #
        # So one uniform limit is picked and applied to BOTH sides. 120 is the
        # conventional Ruby line limit, and it keeps every call the golden
        # splits split.
        LINE_WIDTH = 120

        def on_send(node)
          args = node.arguments
          return if args.empty?
          # A trailing block is not part of the argument list.
          return if node.block_literal?
          return if node.loc.begin.nil? || node.loc.end.nil?
          # `Struct.new` belongs to MultilineStructNew, which lays it out one
          # member per line regardless of width. Its joined form is only 83
          # columns, so without this the two cops would fight forever.
          return if struct_new?(node)
          if args.one?
            join_up(node, args.first)
            return
          end
          # An argument that itself spans lines carries its own layout. In Ruby
          # a newline is a statement separator -- flattening a `lambda { ... }`
          # argument ran its statements together into
          #   lambda { @pending_async_jobs -= 1 QTimer.single_shot(...) if ...
          # which destroyed two methods and stopped the file parsing.
          return if args.any?(&:multiline?)

          if split?(node, args)
            split(node, args)
          else
            join(node, args)
          end
        end
        alias on_csend on_send

        private

        def struct_new?(node)
          node.method?(:new) && node.receiver&.source == "Struct"
        end

        # A call wide enough to need splitting, unless a condition owns it.
        def split?(node, args)
          return false if inside_condition?(node)

          one_line_width(node, args) > LINE_WIDTH
        end

        # The column the call would END at with every argument on one line.
        #
        # The node's START COLUMN is the base, not the line's indentation:
        # `job = RequestEtagJob.new(...)` has the send node beginning at
        # `RequestEtagJob`, so measuring from the indent would lose the
        # `job = ` and under-report by six columns.
        def one_line_width(node, args)
          src = node.source
          range = arguments_range(node)
          from = range.begin_pos - node.source_range.begin_pos
          to = range.end_pos - node.source_range.begin_pos
          flat = (src[0...from] + joined(args) + src[to..]).gsub(/\s*\n\s*/, " ")
          node.source_range.column + flat.length
        end

        # A call sitting in an `if`/`while`/`until` CONDITION is left alone.
        # MultilineCondition owns that layout, and the golden keeps the
        # 186-column `if handle_excluded(...)` on one line rather than break an
        # argument list inside a condition it is also wrapping.
        def inside_condition?(node)
          node.each_ancestor(:if, :while, :until).any? do |ancestor|
            condition = ancestor.condition
            next false if condition.nil?

            condition.source_range.begin_pos <= node.source_range.begin_pos &&
              node.source_range.end_pos <= condition.source_range.end_pos
          end
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

        # One argument per line, `(` and `)` each alone on their own line.
        #
        # The whole parenthesised span is replaced, not just the arguments: an
        # earlier version replaced only the ARGUMENTS range, which left the
        # first argument stranded on the `(` line whenever the C++ had put it
        # there, and nothing downstream moved it -- rubocop does not normalise
        # the indentation of a wrapped argument list (measured with `--only
        # Layout/FirstArgumentIndentation,Layout/ArgumentAlignment`).
        #
        # Comparing against the rendered target makes both this and `join`
        # idempotent: the layout is a function of the node's indent and the
        # argument sources, so one correction reaches a fixed point.
        def split(node, args)
          base = node.source_range.source_line[/\A[ \t]*/]
          body = args.map { |a| "#{base}  #{a.source}" }.join(",\n")
          rewrite(node, "(\n#{body}\n#{base})", MSG_SPLIT)
        end

        def join(node, args)
          rewrite(node, "(#{joined(args)})", MSG)
        end

        def rewrite(node, target, message)
          range = node.loc.begin.join(node.loc.end)
          return if range.source == target

          add_offense(node, message: message) do |corrector|
            corrector.replace(range, target)
          end
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

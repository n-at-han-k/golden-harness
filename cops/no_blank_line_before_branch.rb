# frozen_string_literal: true

module RuboCop
  module Cop
    module Transpile
      # Removes a blank line left at the end of a body, immediately before the
      # `else`, `elsif` or `end` that closes it.
      #
      #   # bad
      #   if a
      #     b
      #
      #   elsif c
      #
      #   # good
      #   if a
      #     b
      #   elsif c
      #
      # No built-in covers this. `Layout/EmptyLinesAroundMethodBody` and the
      # rest of the EmptyLinesAround* family each handle one specific body --
      # a method, a class, a block, a `begin` -- and none of them reaches the
      # branches of an `if` or a `case`. `Layout/EmptyLines` only collapses
      # runs of two or more.
      #
      # Read off both files: 66 of the golden's 67 branch keywords have no
      # blank line before them, and all 202 of its `end`s have none. Each side
      # carried exactly one stray, in a different place, which is precisely the
      # sort of thing that should be settled by a cop over both rather than by
      # hand in one.
      class NoBlankLineBeforeBranch < Base
        extend AutoCorrector
        include RangeHelp

        MSG = 'Remove the blank line before `%<keyword>s`.'

        KEYWORDS = /\A(else|elsif\b|end\b|when\b|rescue\b|ensure\b)/

        def on_new_investigation
          lines = processed_source.lines
          lines.each_with_index do |line, index|
            next unless line.strip.empty?

            following = next_code_line(lines, index + 1)
            next if following.nil?

            match = KEYWORDS.match(lines[following].strip)
            next if match.nil?
            # A run of blanks is Layout/EmptyLines's business; this cop only
            # removes the single blank that abuts the keyword.
            next if index.positive? && lines[index - 1].strip.empty?

            register(index, match[1].strip)
          end
        end

        private

        def register(index, keyword)
          range = range_by_whole_lines(
            processed_source.buffer.line_range(index + 1), include_final_newline: true
          )
          add_offense(range, message: format(MSG, keyword: keyword)) do |corrector|
            corrector.remove(range)
          end
        end

        # The index of the next line with code on it, or nil at end of file.
        def next_code_line(lines, from)
          (from...lines.size).find { |i| !lines[i].strip.empty? }
        end
      end
    end
  end
end

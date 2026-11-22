#!/usr/bin/env ruby
# frozen_string_literal: true

# C++ -> Ruby, as an AST rather than as text.
#
# Replaces 01_build_transform.py and its generated 07_transform.yml. The tree
# walk recurses in Ruby, so there is no DEPTH to unroll: the 43 rewriters that
# file stamped out twelve times each -- 560 of them, 13,950 lines -- are the
# node methods under lib/golden_harness/node.
#
# ast-grep's own docs point here. reference/yaml/rewriter.md: "Rewriters are an
# advanced feature and should be used with caution, and it is experimental at
# the moment. If possible, you can use ast-grep's API as an alternative." The
# API in this tree is tree_haver's tree-sitter backend, already vendored.

require "json"
require "pathname"

require_relative "lib/golden_harness/emitter"
require_relative "lib/golden_harness/node/statement"
require_relative "lib/golden_harness/node/expression"
require_relative "lib/golden_harness/node/log"

SOURCE_SUFFIXES = %w[.h .hpp .cpp .cc .cxx].freeze

def main(argv)
  if argv.size != 1
    warn "usage: 08_emit.rb <workdir>"
    return 2
  end

  root = Pathname.new(argv.first)
  # 09_oracle.rb leaves its answers here. Advisory: without them the emitter
  # falls back to reading the syntax, which is what it did before there was an
  # oracle at all.
  facts_file = root + "facts.json"
  oracle = facts_file.file? ? JSON.parse(facts_file.read) : nil
  count = 0
  failed = []
  root.find do |path|
    next unless path.file? && SOURCE_SUFFIXES.include?(path.extname)

    begin
      ruby = GoldenHarness::Emitter.new(path.read, oracle).emit
    rescue StandardError => error
      # One file is one translation unit. A library-wide run has to report the
      # file that failed and carry on, or a single bad node hides the state of
      # the other eighty-eight.
      failed << [path.relative_path_from(root), error]
      next
    end
    path.write(ruby)
    count += 1
  end
  failed.each { warn "FAILED #{_1}: #{_2.message.lines.first}" }
  puts "emitted #{count} files, #{failed.size} failed"
  failed.empty? ? 0 : 1
end

exit(main(ARGV)) if $PROGRAM_NAME == __FILE__

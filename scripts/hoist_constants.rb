#!/usr/bin/env ruby
# frozen_string_literal: true

# Hoist constant assignments out of method bodies, using Prism.
#
# Why not a RuboCop cop
# ---------------------
# This started as a custom cop (cops/hoist_struct_constant.rb). It cannot work:
# `dynamic constant assignment` is a Lint/Syntax error, which means RuboCop
# fails to build an AST for the file at all, so no cop ever runs on it. The cop
# would need the file to already parse in order to fix the reason it does not.
#
# Prism has no such problem -- it is error tolerant and returns a usable tree
# even when `failure?` is true:
#
#     prism version: 2.1.0
#     failure?: true
#     errors: ["dynamic constant assignment"]
#     has AST: true
#
# so the hoist runs here, before RuboCop sees the file.
#
# What it fixes
# -------------
# C++ allows a type declared inside a function:
#
#     void ProcessDirectoryJob::process() {
#         struct Entries { SyncJournalFileRecord dbEntry; ... };
#     }
#
# The transliteration emits `Entries = Struct.new(...)` where the struct was --
# inside `def process` -- and Ruby rejects that outright. ast-grep cannot fix
# it either: the constant has to MOVE to the enclosing class, and a rewriter
# only ever replaces the node it matched. Hoisting across scopes needs the Ruby
# AST.
#
# Usage: hoist_constants.rb FILE...

require "prism"
require "set"

# A constant write found inside a method, with the lines to move and the line
# to move them above.
Hoist = Struct.new(:source, :from_line, :to_line, keyword_init: true)

def collect(node, enclosing_def, out)
  return unless node.is_a?(Prism::Node)

  case node
  when Prism::DefNode
    # Record THIS def as the hoist target for anything inside it. A nested def
    # keeps the innermost one, which is what matters -- the constant only needs
    # to escape the method it is in.
    enclosing_def = node
  when Prism::ConstantWriteNode
    if enclosing_def
      out << Hoist.new(
        source: node.location.slice,
        from_line: node.location.start_line,
        to_line: enclosing_def.location.start_line
      )
    end
  end

  node.compact_child_nodes.each { |child| collect(child, enclosing_def, out) }
end

def hoist(path)
  src = File.read(path)
  result = Prism.parse(src)
  return 0 if result.value.nil?

  hoists = []
  collect(result.value, nil, hoists)
  return 0 if hoists.empty?

  # Single pass, no index arithmetic. An earlier version deleted the source
  # lines and then inserted at line numbers computed BEFORE the deletions, so
  # every insertion landed in the wrong place and the output stopped parsing
  # ("unexpected end-of-input").
  #
  # Instead: index the hoists by the line they move FROM and the line they
  # move TO, then rebuild the file in one walk.
  drop = hoists.map(&:from_line).to_set
  insert_before = hoists.group_by(&:to_line)

  out = []
  src.lines.each_with_index do |line, i|
    lineno = i + 1
    (insert_before[lineno] || []).each do |h|
      indent = line[/\A[ \t]*/] || ""
      out << "#{indent}#{h.source.strip}\n"
      out << "\n"
    end
    out << line unless drop.include?(lineno)
  end

  File.write(path, out.join)
  hoists.size
end

total = 0
ARGV.each { |path| total += hoist(path) }
warn "hoisted #{total} constant assignment(s)" if total.positive?

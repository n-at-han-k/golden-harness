#!/usr/bin/env ruby
# frozen_string_literal: true

require "prism"
require "set"

Hoist = Struct.new(:source, :from_line, :to_line, keyword_init: true)

def collect(node, enclosing_def, out)
  return unless node.is_a?(Prism::Node)

  case node
  when Prism::DefNode
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

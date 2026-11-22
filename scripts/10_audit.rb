#!/usr/bin/env ruby
# frozen_string_literal: true

# Defects that rubocop cannot see.
#
# `rubocop -A` leaving a file alone means it is laid out the way the goldens
# are. It does NOT mean the Ruby is right, and every one of these was found in
# a golden that was passing the gate:
#
#   * `operator==(const T &lhs, const T &rhs)` emitted `lhs.path == rhs.path`,
#     where neither `lhs` nor `rhs` is defined -- the operand parameters were
#     dropped from the signature and left in the body.
#   * `SyncJournalFileRecord` declares three constructors. All three came out
#     as `def initialize`, so the last silently replaced the other two.
#   * `operator<<` was named `to_s(debug)`, which Ruby calls with no arguments
#     from string interpolation -- `"#{record}"` raised ArgumentError.
#   * `Q_FALLTHROUGH()` reached the output as a call to a macro that does not
#     exist, 30 times in one file.
#
# None of those is a layout question, so no cop was ever going to report them.
# Run over the goldens as a gate on the harness itself, and over a candidate
# before adopting it.

require "parser/current"

# Methods Ruby calls for you, with the arity it calls them at.
#
# Only these matter. Overriding `initialize` at any arity is the whole point of
# `initialize`, and nothing calls it implicitly -- but `to_s` is called with no
# arguments by string interpolation, by `Array#join` and by `puts`, so
# `def to_s(debug)` raises ArgumentError at a distance from where it is
# defined. That one shipped in two goldens before this check existed.
IMPLICIT = {
  to_s: 0, inspect: 0, to_str: 0, to_ary: 0, to_a: 0, to_h: 0, to_hash: 0,
  to_i: 0, to_int: 0, to_sym: 0, to_proc: 0, hash: 0, length: 0, size: 0,
  succ: 0, each: 0, eql?: 1, "<=>": 1, "==": 1, coerce: 1
}.freeze

def arity_collisions(ast)
  each_def(ast).filter_map do |node, line|
    name, args, = *node
    want = IMPLICIT[name]
    next if want.nil?

    arity = args.children.count { _1.type == :arg }
    next if arity == want

    [line, "def #{name}/#{arity}, but Ruby calls #{name}/#{want} implicitly"]
  end
end

# Two definitions of one name in one class: the second wins and the first is
# gone, with nothing to say so.
def duplicate_definitions(ast)
  out = []
  each_scope(ast) do |name, body, _line|
    members(body).select { _1.type == :def }
                 .group_by { _1.children.first }
                 .each do |method, nodes|
      next if nodes.size < 2

      out << [nodes.last.loc.line, "#{name}##{method} defined #{nodes.size} times"]
    end
  end
  out
end

# A macro that reached the output as a call. Ruby has no macros, so an
# ALL_CAPS callee is either a C++ leftover or a constant being called.
MACRO = /\A(Q|OC|OWNCLOUD|SQLITE)_[A-Z0-9_]+\z/

def leaked_macros(ast)
  out = []
  walk(ast) do |node|
    next unless node.type == :send && node.children[0].nil?

    name = node.children[1].to_s
    out << [node.loc.line, "#{name}(...) is a macro, not a method"] if MACRO.match?(name)
  end
  out
end

def members(body)
  return [] if body.nil?

  (body.type == :begin ? body.children : [body]).compact.grep(::Parser::AST::Node)
end

def each_scope(ast, &block)
  walk(ast) do |node|
    next unless %i[class module].include?(node.type)

    name = node.children.first&.children&.last
    body = node.type == :class ? node.children[2] : node.children[1]
    block.call(name, body, node.loc.line)
  end
end

def each_def(ast)
  found = []
  walk(ast) { |node| found << [node, node.loc.line] if node.type == :def }
  found
end

def walk(node, &block)
  return unless node.is_a?(::Parser::AST::Node)

  block.call(node)
  node.children.each { walk(_1, &block) }
end

CHECKS = {
  "arity-collision" => method(:arity_collisions),
  "duplicate-definition" => method(:duplicate_definitions),
  "leaked-macro" => method(:leaked_macros)
}.freeze

def audit(path)
  source = File.read(path)
  ast = begin
    ::Parser::CurrentRuby.parse(source)
  rescue StandardError => error
    return [[0, "unparsable", error.message.lines.first.to_s.strip]]
  end
  return [] if ast.nil?

  CHECKS.flat_map { |name, check| check.call(ast).map { |line, what| [line, name, what] } }
end

def main(argv)
  paths = argv.flat_map { File.directory?(_1) ? Dir["#{_1}/**/*.rb"] : [_1] }.sort
  if paths.empty?
    warn "usage: 10_audit.rb <file-or-directory>..."
    return 2
  end

  findings = paths.flat_map { |path| audit(path).map { |line, kind, what| [path, line, kind, what] } }
  findings.sort_by { [_1[0], _1[1]] }
          .each { |path, line, kind, what| puts "#{path}:#{line}: #{kind}: #{what}" }
  puts "#{paths.size} files audited, #{findings.size} findings"
  findings.empty? ? 0 : 1
end

exit(main(ARGV)) if $PROGRAM_NAME == __FILE__

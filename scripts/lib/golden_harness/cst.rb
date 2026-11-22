# frozen_string_literal: true

module GoldenHarness
  # The C++ side: a thin reader over one tree-sitter tree.
  #
  # tree-sitter's own node API is byte-oriented and has no text accessor, so
  # every lookup a rule used to spell as `has: { field: x, kind: y }` is a
  # method here. Named children only, like ast-grep's `has`.
  class Cst
    def initialize(source)
      @source = source.dup.force_encoding(Encoding::BINARY)
      @tree = TreeSitterLanguagePack.get_parser("cpp").parse_bytes(@source)
    end

    def root = @tree.root_node

    # The node's own source text. tree-sitter counts in bytes, so the slice is
    # taken in bytes and handed back as UTF-8.
    def text(node)
      return "" if node.nil?

      @source.byteslice(node.start_byte, node.end_byte - node.start_byte)
            .dup.force_encoding(Encoding::UTF_8)
    end

    # The source between two byte offsets -- what a splice keeps verbatim.
    def between(from, to)
      return "" if to <= from

      @source.byteslice(from, to - from).dup.force_encoding(Encoding::UTF_8)
    end

    # The source line a node starts on, counted from the bytes before it.
    # What it is for: the author's line breaks inside a `<<` chain, which are
    # the only record of how they grouped a long message.
    def line(node)
      return 0 if node.nil?

      @source.byteslice(0, node.start_byte).count("\n")
    end

    def named(node)
      return [] if node.nil?

      Array.new(node.named_child_count) { |i| node.named_child(i) }
    end

    def field(node, name)
      node && node.child_by_field_name(name.to_s)
    end

    # `has: { field: f, kind: k }` -- a DIRECT named child.
    def child(node, kind, field: nil)
      if field
        found = field(node, field)
        return found if found && found.kind == kind.to_s

        return nil
      end
      named(node).find { _1.kind == kind.to_s }
    end

    # `has: { field: f, stopBy: end, kind: k }` -- anywhere below, optionally
    # scoped to one field. Scoping matters: searching a parameter's whole
    # subtree for an identifier finds the TYPE's name before the parameter's.
    def dig(node, *kinds, field: nil)
      base = field ? field(node, field) : node
      return nil if base.nil?

      wanted = kinds.map(&:to_s)
      return base if wanted.include?(base.kind)

      named(base).each do |kid|
        found = dig(kid, *kinds)
        return found if found
      end
      nil
    end

    def dig?(node, *kinds, field: nil) = !dig(node, *kinds, field: field).nil?

    # Every descendant, preorder, the node itself included.
    def each_node(node, &block)
      return if node.nil?

      block.call(node)
      named(node).each { each_node(_1, &block) }
    end

    def descendants(node)
      out = []
      each_node(node) { out << _1 }
      out
    end

    # `inside: { kind: k }` -- the DIRECT parent, with no stopBy.
    def parent?(node, kind) = node.parent && node.parent.kind == kind.to_s

    # `inside: { kind: k, stopBy: end }` -- any ancestor.
    def within?(node, kind)
      at = node.parent
      while at
        return true if at.kind == kind.to_s

        at = at.parent
      end
      false
    end

    # The last named child, for `nthChild: { position: 1, reverse: true }`.
    def last_named(node) = named(node).last
  end
end

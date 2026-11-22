# frozen_string_literal: true

module GoldenHarness
  # Whole-file facts, gathered once before the walk.
  #
  # These are the questions a single node cannot answer. The old pipeline asked
  # them with a negative whole-file `not: inside: translation_unit` search per
  # identifier, which is quadratic and had to be restated in every tier; here
  # each is one pass.
  class Facts
    # `lcDisco` -> "sync.discovery", recovered from the attribute 02_prepare.py
    # leaves behind for Q_LOGGING_CATEGORY.
    CATEGORY = /\A\s*(\w+)\s*,\s*\\?"([^"\\]+)/

    # An enum value as the C++ writes it: PascalCase with a lowercase second
    # letter, which is what tells `NormalQuery` from an acronym.
    ENUM_VALUE = /\A[A-Z][a-z][A-Za-z0-9]*\z/

    def initialize(cst, oracle = nil)
      @cst = cst
      @oracle = oracle || {}
      @categories = {}
      @receivers = Set.new
      @lambdas = {}
      scan
    end

    def category(ident) = @categories[ident]

    def category?(ident) = @categories.key?(ident)

    # True when this name is an enum value rather than a class.
    #
    # 09_oracle.rb answers this from the headers, so where it has an answer
    # there is no guessing: the name is an enum constant, or it is a type, and
    # libclang knows which. ALL_CAPS is excluded either way -- both goldens
    # keep `CSYNC_INSTRUCTION_NEW` as a Ruby constant, which is a style
    # decision the oracle has no opinion about.
    #
    # The fallback is the old file-local reading, for a name whose header this
    # translation unit does not include: a class appears as a RECEIVER
    # somewhere -- a `::` scope, a callee, the left of a `.` -- and an enum
    # value never does.
    def enum_value?(name)
      # PascalCase only. That is the shape an enum constant takes here, and it
      # is the only shape that is AMBIGUOUS -- a lowercase name is a local, and
      # asking the oracle about one invites a false positive, because some
      # header in the tree does declare an enum constant called `async`.
      return false unless name.match?(/\A[A-Z]/)
      return false unless name.match?(/[a-z]/)

      known = enum_constants[name]
      return true if known
      return false if records.include?(name)

      ENUM_VALUE.match?(name) && !@receivers.include?(name)
    end

    # The empty value a declared type starts life as: "array", "set", "hash",
    # "string", "int", "bool" or "object:ClassName". Nil when unknown.
    def shape(name, scope = nil)
      shapes = @oracle.fetch("shapes", {})
      (scope && shapes["#{scope}::#{name}"]) || shapes[name]
    end

    # A function with internal linkage -- `static`, or inside an anonymous
    # namespace -- is private to the translation unit, which in Ruby is a
    # private method.
    def internal?(name) = internal.include?(name)

    # Names bound to a lambda inside this function, so a call to one emits
    # `.call` rather than reading as a method.
    def lambda?(function, name)
      (@lambdas[function&.start_byte] || Set.new).include?(name)
    end

    private

      def enum_constants = @enum_constants ||= @oracle.fetch("enum_constants", {})

      def records = @records ||= Set.new(@oracle.fetch("records", []))

      def internal = @internal ||= Set.new(@oracle.fetch("internal", []))

      def scan
        @cst.each_node(@cst.root) do |node|
          case node.kind
          when "attributed_declarator", "attribute", "attribute_declaration"
            note_category(node)
          when "qualified_identifier"
            scope = @cst.field(node, :scope)
            @receivers << @cst.text(scope) if scope
          when "call_expression"
            fn = @cst.field(node, :function)
            @receivers << @cst.text(fn) if fn && fn.kind == "identifier"
          when "field_expression"
            arg = @cst.field(node, :argument)
            @receivers << @cst.text(arg) if arg && arg.kind == "identifier"
          when "function_definition"
            note_lambdas(node)
          end
        end
      end

      def note_category(node)
        text = @cst.text(node)
        return unless text.include?("q_logging_category")

        inner = text[/q_logging_category\s*\(\s*"(.*)"\s*\)/m, 1]
        return if inner.nil?

        m = CATEGORY.match(inner)
        @categories[m[1]] = m[2] if m
      end

      def note_lambdas(function)
        names = Set.new
        @cst.each_node(function) do |node|
          next unless node.kind == "init_declarator"

          # The value must BE a lambda, not merely contain one: an
          # immediately-invoked `[&]{ ... }()` is the value it returns, so the
          # name it binds is an ordinary local and calling it would be wrong.
          value = @cst.field(node, :value)
          next unless value && value.kind == "lambda_expression"

          name = @cst.dig(node, "identifier", field: :declarator)
          names << @cst.text(name) if name
        end
        @lambdas[function.start_byte] = names
      end
  end
end

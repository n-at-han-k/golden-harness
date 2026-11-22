# frozen_string_literal: true

require "set"
require "tree_sitter_language_pack"

require_relative "cst"
require_relative "dsl"
require_relative "facts"

module GoldenHarness
  # C++ translation unit -> Ruby source.
  #
  # The walk builds a `parser` AST and unparser prints it, so every layout
  # question -- indentation, where a line breaks, `do ... end` versus braces,
  # which parentheses are needed -- belongs to the printer and then to rubocop.
  # Nothing here emits text except the prologue, which carries the file's
  # leading comment and its requires, neither of which an AST can hold.
  class Emitter
    include DSL

    # `#include <QFile>` -> `require "qfile"`; a quoted include names a file in
    # the tree, so it is require_relative and loses its extension.
    HEADER_EXT = /\.(h|hpp|hxx)\z/

    # A comment line's leader: `/*`, ` *`, ` */` or `//`.
    COMMENT_LEADER = /^[ \t]*(?:\/\*+|\/\/+|\*+\/|\*)[ \t]?/

    SHEBANG = "#!/usr/bin/env ruby"

    def initialize(source, oracle = nil)
      @cst = Cst.new(source)
      @facts = Facts.new(@cst, oracle)
      @function = nil
      @hoisted = []
      @private_members = []
      @method_name = nil
      @ternary_branch = {}
    end

    def emit
      body = program
      ruby = body.nil? ? "" : Unparser.unparse(body)
      [prologue, ruby].reject(&:empty?).join("\n") + "\n"
    end

    private

      # The shebang, the file's leading comment block, and the requires.
      #
      # Text rather than AST on purpose. A `parser` AST holds no comments at
      # all, and the blank lines between include groups are the C++ author's
      # grouping -- information the tree does not carry and unparser would
      # drop. rubocop leaves requires alone in both directions, so if they were
      # not written out here the grouping would be lost.
      def prologue
        lines = [SHEBANG]
        lines.concat(header_comment)
        requires.each { |line| lines << line }
        # A blank line before the body: rubocop will not add one next to a
        # require, so it has to be written here.
        lines << ""
        lines.join("\n")
      end

      def header_comment
        first = @cst.named(@cst.root).first
        return [] unless first && first.kind == "comment"

        @cst.text(first).gsub(COMMENT_LEADER, "# ").split("\n").map(&:rstrip)
      end

      # One line per include, with a blank line wherever the C++ had one, so
      # the author's grouping survives.
      def requires
        out = []
        previous = nil
        @cst.named(@cst.root).each do |node|
          next unless node.kind == "preproc_include"

          out << "" if previous.nil? || blank_between?(previous, node)
          out << require_line(node)
          previous = node
        end
        out
      end

      def require_line(node)
        path = @cst.field(node, :path)
        text = @cst.text(path)
        if path.kind == "system_lib_string"
          %(require "#{text.delete("<>").downcase}")
        else
          %(require_relative "#{text.delete('"').sub(HEADER_EXT, "")}")
        end
      end

      # An include's node extent runs to the end of its line, so two adjacent
      # includes have NO newline between them and a blank line shows up as one.
      def blank_between?(before, after)
        @cst.between(before.end_byte, after.start_byte).count("\n") >= 1
      end

      # The namespaces, and anything at file scope outside one.
      def program
        Body(@cst.named(@cst.root).flat_map { top_level(_1) }.compact)
      end

      def top_level(node)
        case node.kind
        when "namespace_definition" then namespace(node)
        when "struct_specifier", "class_specifier" then [struct(node)]
        when "enum_specifier" then [enum(node)]
        when "function_definition" then function(node)
        else []
        end
      end

      # `namespace OCC { void A::f() {} }` -> `module OCC / class A`.
      #
      # One class per namespace, recovered from the first qualified method name
      # in it. That is what the C++ gives: a free function at namespace scope
      # has no scope of its own, and the golden puts such helpers in the class
      # with the methods they serve.
      def namespace(node)
        body = @cst.field(node, :body)
        named = @cst.dig(node, "namespace_identifier", field: :name)

        # `namespace { ... }` with no name gives its contents INTERNAL LINKAGE:
        # they are private to the translation unit. Ruby's equivalent is a
        # private method, so they are held back and emitted under `private` at
        # the end of the class rather than wrapped in a module of their own.
        unless named
          @private_members.concat(@cst.named(body).flat_map { top_level(_1) }.compact)
          return []
        end

        members = @hoisted + @cst.named(body).flat_map { top_level(_1) }.compact
        @hoisted = []
        inner = class_name(body)
        members += [Call(nil, :private), *@private_members] if @private_members.any?
        @private_members = []
        [Module_(@cst.text(named), inner ? Class_(inner, Body(members)) : Body(members))]
      end

      def class_name(body)
        found = @cst.descendants(body).find { _1.kind == "qualified_identifier" }
        return nil if found.nil?

        scope = @cst.field(found, :scope)
        scope && @cst.text(scope)
      end

      # A definition, in source position.
      #
      # NOT placed by linkage. The oracle knows which functions have internal
      # linkage -- a `static` free function as much as one in an anonymous
      # namespace -- but the golden keeps a `static` helper public and in
      # place (`compute_local_checksum`), and reserves `private` for the
      # anonymous namespace, which `namespace` handles structurally. The fact
      # is recorded either way; placement does not use it.
      def function(node)
        [method(node)].compact
      end

      # `void A::f(a, b) { ... }` -> `def f(a, b)`.
      def method(node)
        declarator = @cst.dig(node, "function_declarator", field: :declarator)
        return nil if declarator.nil?

        name = method_name(declarator)
        return nil if name.nil?

        @function = node
        @method_name = name
        statements = statements_of(@cst.field(node, :body))
        @function = nil
        @method_name = nil
        Def(name, parameters(declarator), Body(statements))
      end

      def method_name(declarator)
        qualified = @cst.dig(declarator, "qualified_identifier", field: :declarator)
        return @cst.text(@cst.dig(qualified, "identifier")) if qualified

        plain = @cst.dig(declarator, "identifier", "field_identifier", field: :declarator)
        plain && snake(@cst.text(plain))
      end

      def parameters(declarator)
        list = @cst.field(declarator, :parameters)
        @cst.named(list).filter_map do |param|
          case param.kind
          when "parameter_declaration"
            name = @cst.dig(param, "identifier", field: :declarator)
            name ? @cst.text(name) : "_"
          when "variadic_parameter_declaration"
            "*#{@cst.text(@cst.dig(param, "identifier", field: :declarator))}"
          end
        end
      end

      # A plain-data struct is a Struct, which is a constant, so it is hoisted
      # to the class body rather than left where the C++ declared it.
      def struct(node)
        name = @cst.text(@cst.field(node, :name))
        fields = @cst.named(@cst.field(node, :body)).filter_map do |field|
          next if @cst.dig?(field, "function_declarator")

          id = @cst.dig(field, "field_identifier", field: :declarator)
          id && Sym(@cst.text(id))
        end
        Constant(name, Call(Const(:Struct), :new, *fields, kwarg(:keyword_init, True_())))
      end

      def enum(node)
        name = @cst.text(@cst.field(node, :name))
        values = @cst.named(@cst.field(node, :body)).filter_map do |e|
          id = @cst.field(e, :name)
          id && Constant(@cst.text(id), Sym(@cst.text(id)))
        end
        Module_(name, Body(values))
      end

      # Trailing keyword arguments are `kwargs`, not a `hash`: as a hash
      # unparser writes the braces, giving `Struct.new(:a, { keyword_init: true })`.
      def kwarg(key, value) = n(:kwargs, n(:pair, Sym(key), value))

      # ast-grep's snakeCase: a break before every capital, then downcase.
      #
      # A name with no capital is already snake and a name with no lowercase is
      # a constant -- `CSYNC_INSTRUCTION_NEW` -- and neither is touched. What
      # is left is PascalCase, including a single word like `Excluded`, which
      # still has to come down to `excluded`.
      def snake(name)
        return name unless name.match?(/[A-Z]/)
        return name unless name.match?(/[a-z]/)

        name.gsub(/(?<=.)([A-Z])/) { "_#{::Regexp.last_match(1)}" }.downcase
      end
  end
end

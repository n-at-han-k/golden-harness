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
    HEADER_EXT_BARE = /\.(h|hpp|hxx)\z/

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
      @class_name = nil
      @pending_updates = nil
      @pending_before = nil
      @operator_lhs = nil
      @operator_rhs = nil
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
        usings.each { |line| lines << "" << line }
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
          # `<sqlite3.h>` -> `require "sqlite3"`. A Ruby require names a
          # library, never a header file, so the extension goes here too.
          %(require "#{text.delete("<>").downcase.sub(HEADER_EXT_BARE, "")}")
        else
          %(require_relative "#{text.delete('"').sub(HEADER_EXT, "")}")
        end
      end

      # An include's node extent runs to the end of its line, so two adjacent
      # includes have NO newline between them and a blank line shows up as one.
      # `using namespace Qt::Literals::StringLiterals;` -> `include ...`.
      #
      # A using-directive brings a namespace's names into scope, which is what
      # `include` does with a module's. At file scope, like the C++: in the
      # class body rubocop's EmptyLinesAfterModuleInclusion and
      # BlankLineBetweenStatements disagree about the blank line after it and
      # never settle.
      def usings
        @cst.named(@cst.root).filter_map do |node|
          next unless node.kind == "using_declaration"
          next unless @cst.text(node).include?("namespace")

          name = @cst.text(node)[/namespace\s+([\w:]+)/, 1]
          name && "include #{name}"
        end
      end

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
        # Known before the members are walked: a constructor is recognised by
        # its name matching the class's.
        inner = class_name(body)
        @class_name = inner

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
        operator = operator_equality(node)
        return operator if operator

        [method(node)].compact
      end

      # A free `operator==(const T &lhs, const T &rhs)` is T's own `==`.
      #
      #   bool operator==(const SyncJournalDb::DownloadInfo &lhs,
      #                   const SyncJournalDb::DownloadInfo &rhs)
      #
      # becomes `class DownloadInfo / def ==(other)`, because in Ruby equality
      # is a method on the left operand: `lhs` is the receiver and its members
      # are ivars, `rhs` is the argument. C++ has to write it as a free
      # function to get the symmetry; Ruby does not.
      def operator_equality(node)
        declarator = @cst.dig(node, "function_declarator", field: :declarator)
        return nil if declarator.nil?

        name = @cst.dig(declarator, "operator_name", field: :declarator) ||
               @cst.child(declarator, "operator_name")
        return nil if name.nil? || @cst.text(name) != "operator=="

        parameters = @cst.named(@cst.field(declarator, :parameters))
        return nil unless parameters.size == 2

        type = @cst.dig(parameters.first, "type_identifier")
        return nil if type.nil?

        @operator_lhs = @cst.text(@cst.dig(parameters[0], "identifier", field: :declarator))
        @operator_rhs = @cst.text(@cst.dig(parameters[1], "identifier", field: :declarator))
        @function = node
        body = Body(statements_of(@cst.field(node, :body)))
        @function = nil
        @operator_lhs = nil
        @operator_rhs = nil

        [Class_(@cst.text(type), Def("==", ["other"], body))]
      end

      # `void A::f(a, b) { ... }` -> `def f(a, b)`.
      def method(node)
        declarator = @cst.dig(node, "function_declarator", field: :declarator)
        return nil if declarator.nil?

        name = method_name(declarator)
        return nil if name.nil?

        @function = node
        @method_name = name
        statements = field_initializers(node) + statements_of(@cst.field(node, :body))
        @function = nil
        @method_name = nil

        Def(ruby_method_name(name, declarator),
            parameters(declarator, @cst.field(node, :body)), Body(statements))
      end

      # The member initialiser list, which runs before the body.
      #
      #   SyncJournalDb::SyncJournalDb(path, parent)
      #       : QObject(parent), _dbFile(path), _transaction(0)
      #
      # becomes `super(parent)` followed by one assignment per member, in the
      # order the C++ writes them. The base-class entry is the one whose name
      # is a type rather than a member, which is what PascalCase marks.
      def field_initializers(node)
        list = @cst.child(node, "field_initializer_list")
        return [] if list.nil?

        @cst.named(list).filter_map do |initialiser|
          name = @cst.named(initialiser).first
          next if name.nil?

          values = @cst.named(@cst.child(initialiser, "argument_list") || initialiser)
                       .filter_map { expr(_1) }
          text = @cst.text(name)
          if text.match?(/\A[A-Z]/)
            Super(*values)
          else
            IvarSet(snake(text.sub(/\A_/, "")), values.first)
          end
        end
      end

      # A constructor is `initialize`; a destructor is `finalize`, which is the
      # name Ruby gives the hook that runs when an object goes away. Both are
      # spelled with the class's own name in C++, and the `~` is the only thing
      # that tells them apart.
      def ruby_method_name(name, declarator)
        return name unless name == @class_name

        @cst.dig?(declarator, "destructor_name") ? "finalize" : "initialize"
      end

      def method_name(declarator)
        qualified = @cst.dig(declarator, "qualified_identifier", field: :declarator)
        return @cst.text(@cst.dig(qualified, "identifier")) if qualified

        plain = @cst.dig(declarator, "identifier", "field_identifier", field: :declarator)
        plain && snake(@cst.text(plain))
      end

      def parameters(declarator, body = nil)
        list = @cst.field(declarator, :parameters)
        @cst.named(list).filter_map do |param|
          case param.kind
          when "parameter_declaration"
            name = @cst.dig(param, "identifier", field: :declarator)
            next "_" if name.nil?

            unused?(body, @cst.text(name)) ? "_#{@cst.text(name)}" : @cst.text(name)
          when "variadic_parameter_declaration"
            "*#{@cst.text(@cst.dig(param, "identifier", field: :declarator))}"
          end
        end
      end

      # A parameter the body never mentions.
      #
      # Ruby marks one with a leading underscore, and `Q_UNUSED(x)` -- which
      # 02_prepare.py leaves and the emitter drops -- is the C++ saying the
      # same thing. rubocop reports this as Lint/UnusedMethodArgument but will
      # not correct it under `-A`, so it is done here.
      def unused?(body, name)
        return false if body.nil?

        @cst.descendants(body).none? do |node|
          %w[identifier field_identifier].include?(node.kind) && @cst.text(node) == name
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

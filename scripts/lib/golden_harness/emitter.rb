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
      @method_name = nil
      @class_name = nil
      @open_scope = nil
      @pending_updates = nil
      @pending_before = nil
      @constants = Set.new
      @condition_targets = Set.new
      @operator_lhs = nil
      @operator_rhs = nil
      @ternary_branch = {}
    end

    def emit
      body = program
      body = sends_for_free_names(body) unless body.nil?
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

      # `using namespace FileSystem::SizeLiterals;` written INSIDE the
      # namespace, which belongs to the module rather than to the file.
      # A file-scope constant that the unreachable code was the only reader of.
      # `win_device_names` and `win_system_files` exist for
      # `csync_is_windows_reserved_word` and for nothing else.
      #
      # Deliberately narrow: a constant has to be read by the DEAD code to be
      # a candidate, so a genuinely unused one -- an exported constant this
      # file only declares -- is still emitted.
      def orphaned?(name)
        mentions(name) < 2 && dead_mentions(name).positive?
      end

      def mentions(name) = live_names.fetch(name, 0)

      def dead_mentions(name) = dead_names.fetch(name, 0)

      def live_names = (@name_counts ||= count_names)[:live]

      def dead_names = (@name_counts ||= count_names)[:dead]

      # Every identifier in the file, split by whether it stands in a function
      # the oracle marked unreachable.
      def count_names
        ranges = @cst.descendants(@cst.root)
                     .select { _1.kind == "function_definition" && dead?(_1) }
                     .map { [_1.start_byte, _1.end_byte] }
        counts = { live: Hash.new(0), dead: Hash.new(0) }
        @cst.each_node(@cst.root) do |node|
          next unless node.kind == "identifier"

          at = node.start_byte
          where = ranges.any? { |from, to| at >= from && at < to } ? :dead : :live
          counts[where][@cst.text(node)] += 1
        end
        counts
      end

      def usings_in(body)
        @cst.named(body).filter_map do |node|
          next unless node.kind == "using_declaration"
          next unless @cst.text(node).include?("namespace")

          name = @cst.text(node)[/namespace\s+([\w:]+)/, 1]
          name && Call(nil, :include, ConstPath(name))
        end
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
        # A file with no `namespace` of its own still defines a class:
        # csync_exclude.cpp declares `ExcludedFiles` globally, and the golden is
        # a bare top-level `class ExcludedFiles`. Without this its methods came
        # out as top-level defs and the constructor was never recognised.
        return Body(class_blocks(@cst.root)) unless namespaced?

        Body(@cst.named(@cst.root).flat_map { top_level(_1) }.compact)
      end

      def namespaced?
        @cst.named(@cst.root).any? do |node|
          node.kind == "namespace_definition" &&
            !@cst.dig(node, "namespace_identifier", field: :name).nil?
        end
      end

      def top_level(node)
        case node.kind
        when "declaration" then namespace_constant(node)
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

        # `namespace { ... }` with no name gives its contents internal linkage.
        # They are still ordinary members of the class the file defines: the
        # goldens keep them public and in source position -- csync_exclude's
        # `csync_exclude_expand_escapes`, owncloudpropagator's
        # `critical_free_space_limit`, discovery's `static
        # compute_local_checksum`.
        #
        # Hoisted rather than returned, because the block is a SIBLING of the
        # named namespace, not a member of it: syncjournaldb.cpp writes
        # `namespace { ... }` and then `namespace OCC { ... }`, so returning
        # them put `get_p_hash` at the top of the file outside the module. The
        # first class to be opened claims them, which is also the rule a
        # constant among them follows -- Ruby cannot assign one in a method.
        unless named
          @cst.named(body).flat_map { top_level(_1) }.compact.each { hoist_into(nil, _1) }
          return []
        end

        [Module_(@cst.text(named), Body(usings_in(body) + class_blocks(body)))]
      end

      # One `class` block per RUN of definitions sharing a scope, in source
      # order.
      #
      # owncloudpropagator.cpp defines methods of seven classes, interleaved --
      # `OwncloudPropagator`, then `PropagateItemJob`, then `OwncloudPropagator`
      # again -- and the golden reopens each as the source moves between them.
      # Assuming one class per namespace put all 57 methods into the first and
      # lost every constructor and destructor except that class's own.
      def class_blocks(body)
        blocks = []
        scope = :none
        current = []

        @cst.named(body).each do |child|
          if child.kind == "function_definition"
            # A free function at namespace scope keeps the scope it is written
            # among, which is where the golden puts such a helper.
            # A free function at namespace scope has no scope of its own. One
            # written BEFORE any method stays unresolved, so the first class to
            # come along claims it -- owncloudpropagator.cpp opens with
            # `criticalFreeSpaceLimit()` and the golden puts it at the top of
            # `class OwncloudPropagator`. One written after a method inherits
            # that method's class, which is where such a helper belongs.
            at = definition_scope(child) || (scope == :none ? :none : scope)
            if scope == :none
              scope = at
            elsif at != scope
              blocks << [scope, current] unless current.empty?
              scope = at
              current = []
            end
            @class_name = at
            # The class block currently OPEN, which is what tells a free
            # `operator<<` whether it is already inside the class it streams.
            # `@class_name` is not that: it outlives the namespace walk, so an
            # operator written AFTER `namespace OCC { }` closes still saw the
            # last class set inside it.
            @open_scope = at
            current.concat(function(child))
            @open_scope = nil
          else
            current.concat(top_level(child))
          end
        end
        blocks << [scope, current] unless current.empty?

        assemble(blocks)
      end

      # The hoisted members join the first block: its constants at the very
      # top, its methods after the initializer.
      def assemble(blocks)
        return [] if blocks.empty?

        hoisted = @hoisted
        @hoisted = []
        hoisted.group_by(&:first).each do |scope, pairs|
          members = pairs.map(&:last)
          # The block the member was written in, or the first one -- which is
          # where a file-scope hoist belongs, there being no method it came
          # from.
          target = blocks.find { _1.first == scope } || blocks.first
          constants, methods = members.partition { _1.type == :casgn }
          target[1] = constants + after_initializer(methods, target[1])
        end

        blocks.map do |(scope, members)|
          members = order_members(members)
          next Body(members) if scope.nil? || scope == :none

          # `OCC::operator<<(...)` is qualified with a NAMESPACE, not a class,
          # and `class OCC` is wrong -- the oracle knows which names are
          # records, and everything else that can hold a definition is a
          # namespace.
          @facts.record?(scope) ? Class_(scope, Body(members)) : Module_(scope, Body(members))
        end
      end

      # A member lifted out of a method body to the class that holds it.
      #
      # `struct AbortsFinished { ... }` is declared inside
      # `PropagateRootDirectory::abort` and Ruby has no struct-in-a-method, so
      # it becomes a class-level `Struct.new` -- of THAT class. A single
      # file-wide list put it in the first class the file opens.
      def hoist_into(scope, member)
        @hoisted << [scope, member]
      end

      # `Layout/ClassStructure`'s order, applied here because its own
      # autocorrect moves the def but writes `end    def parse_checksum_header`
      # -- unparsable, which stops every other cop in the run. Constants open
      # the class, then the initializer, then everything else in source order.
      def order_members(members)
        constants, rest = members.partition { _1.type == :casgn }
        initializer, others = rest.partition { initializer?(_1) }
        constants + initializer + others
      end

      def initializer?(node) = node.type == :def && node.children.first == :initialize

      # `Layout/ClassStructure` puts `initializer` ahead of `public_methods`,
      # which is the order csync_exclude's golden has -- the anonymous
      # namespace is written first in the C++ and `initialize` still comes
      # first. Done here rather than left to the cop: its autocorrect moves the
      # def but writes `end    def get_p_hash`, which does not parse, and every
      # cop after it in the run is then skipped.
      def after_initializer(methods, members)
        return members if methods.empty?

        at = members.index { initializer?(_1) }
        at ? members[0..at] + methods + members[(at + 1)..] : methods + members
      end

      def definition_scope(node)
        declarator = @cst.dig(node, "function_declarator", field: :declarator)
        qualified = declarator && @cst.dig(declarator, "qualified_identifier", field: :declarator)
        scope = qualified && @cst.field(innermost(qualified), :scope)
        scope ? @cst.text(scope) : nil
      end

      # The LAST qualifier before the name.
      #
      # `void OCC::SyncEngine::slotItemDiscovered(...)` nests one
      # qualified_identifier inside another, and reading the outer one's scope
      # gave `OCC` -- the namespace, not the class. The method then opened a
      # second block of its own and the class came out split in two.
      def innermost(qualified)
        at = qualified
        while (inner = @cst.child(at, "qualified_identifier", field: :name))
          at = inner
        end
        at
      end

      # The class these definitions belong to.
      #
      # Taken from a qualified name that is a FUNCTION DEFINITION's declarator,
      # not from the first qualified name anywhere in the namespace: folder.cpp
      # opens with `using namespace FileSystem::SizeLiterals;`, and reading that
      # one gave `class FileSystem` and lost the constructor with it.
      def class_name(body)
        @cst.descendants(body).each do |node|
          next unless node.kind == "function_definition"

          declarator = @cst.dig(node, "function_declarator", field: :declarator)
          qualified = declarator && @cst.dig(declarator, "qualified_identifier", field: :declarator)
          scope = qualified && @cst.field(innermost(qualified), :scope)
          return @cst.text(scope) if scope
        end
        nil
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
        return [] if dead?(node)

        operator = operator_equality(node) || operator_stream(node)
        return operator if operator

        [method(node)].compact
      end

      # A function the oracle found nothing can reach.
      #
      # `02_prepare` resolves the platform conditionals, so the `#ifdef _WIN32`
      # block holding the only call to `csync_is_windows_reserved_word` is gone
      # -- but its definition sits OUTSIDE the conditional, so the preprocessor
      # pass has nothing to remove it by and it survives with no caller and no
      # declaration in any header.
      def dead?(node)
        name = unqualified_name(node)
        !name.nil? && @facts.dead?(snake(name))
      end

      # The declarator's own name, only when it is unqualified: a `Class::name`
      # definition is a method, reached through its class, and is never dead.
      def unqualified_name(node)
        declarator = @cst.dig(node, "function_declarator", field: :declarator)
        name = declarator && @cst.child(declarator, "identifier", field: :declarator)
        name && @cst.text(name)
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

      # `QDebug OCC::operator<<(QDebug debug, const SyncJournalFileRecord &r)`
      # renders a record, which in Ruby is the record's own `to_s`. Both names
      # stay locals, because the body writes into `debug` as well as reading
      # `r` -- unlike `operator==`, where the left operand becomes the
      # receiver.
      #
      # Without this the declarator has no `identifier` at all and the emitter
      # wrote `def (debug, record)`, which does not parse -- so rubocop
      # corrected nothing in the file.
      def operator_stream(node)
        declarator = @cst.dig(node, "function_declarator", field: :declarator)
        return nil if declarator.nil?

        name = @cst.dig(declarator, "operator_name", field: :declarator) ||
               @cst.child(declarator, "operator_name")
        return nil if name.nil? || @cst.text(name) != "operator<<"

        parameters = @cst.named(@cst.field(declarator, :parameters))
        return nil unless parameters.size == 2

        type = @cst.dig(parameters[1], "type_identifier")
        stream = @cst.dig(parameters[0], "identifier", field: :declarator)
        record = @cst.dig(parameters[1], "identifier", field: :declarator)
        return nil if type.nil? || stream.nil? || record.nil?
        # A Ruby class name is a CONSTANT. `operator<<(QDebug,
        # std::chrono::nanoseconds)` streams a type whose own name is
        # lowercase, and `class nanoseconds` does not parse; it stays an
        # ordinary free method instead.
        return nil unless @cst.text(type).match?(/\A[A-Z]/)

        @function = node
        # The RECORD becomes the receiver, the same way `operator==`'s left
        # operand does: `record.hasError()` is `has_error` and `record._path`
        # is `@path`. Without this the parameter was dropped from the
        # signature and its name left dangling through the whole body.
        @operator_lhs = @cst.text(record)
        body = Body(statements_of(@cst.field(node, :body)))
        @operator_lhs = nil
        @function = nil

        # Named after the operator, as a member `operator==` is -- NOT `to_s`,
        # which was the first choice and is a trap: `to_s` is called with no
        # arguments by string interpolation and by `Array#join`, so
        # `"#{record}"` raised ArgumentError on every record in the file.
        method = Def(OPERATORS.fetch("operator<<"), [@cst.text(stream)], body)
        # Already inside the class this streams: the method joins that body
        # rather than opening a second block. `class Path` wrapped around it
        # inside the open `class Path` of path.cpp declared `Path::Path`, a
        # NESTED class, and the operator went on that instead of on `Path`.
        return [method] if @cst.text(type) == @open_scope

        [Class_(@cst.text(type), method)]
      end

      # `void A::f(a, b) { ... }` -> `def f(a, b)`.
      def method(node)
        declarator = @cst.dig(node, "function_declarator", field: :declarator)
        return nil if declarator.nil?

        name = method_name(declarator)
        return nil if name.nil?

        @function = node
        @method_name = name
        # A member initialiser can hoist: `PropagateRootDirectory` builds its
        # root item with an immediately-invoked lambda and passes it to
        # `super`, and the binding has to land before the `super` line.
        before = []
        @pending_before = before
        initialisers = field_initializers(node)
        @pending_before = nil
        statements = before + initialisers + statements_of(@cst.field(node, :body))
        @function = nil
        @method_name = nil

        Def(ruby_method_name(name, declarator), parameters(declarator, node), Body(statements))
      end

      # The member initialiser list, which runs before the body.
      #
      #   SyncJournalDb::SyncJournalDb(path, parent)
      #       : QObject(parent), _dbFile(path), _transaction(0)
      #
      # becomes `super(parent)` followed by one assignment per member, in the
      # order the C++ writes them. The base-class entry is the one whose name
      # is a type rather than a member, which is what PascalCase marks.
      # What a member initialiser initialises the member TO.
      #
      # `_subJobs(propagator, path)` CONSTRUCTS a PropagatorCompositeJob -- the
      # declared type is the only thing that says so, and taking the first
      # argument left `@sub_jobs = propagator`, which is a different object.
      #
      # Only with MORE THAN ONE argument. A single one is the value itself:
      # `_account(account)` holds a QSharedPointer and the golden writes
      # `@account = account`, not `QSharedPointer.new(account)`.
      def member_value(member, values)
        return values.first unless values.size > 1

        shape = @facts.shape(member) || @facts.shape("_#{member}")
        # The oracle spells the type as libclang sees it, namespace included.
        # Inside `module OCC` the golden writes `PropagatorCompositeJob.new`.
        type = shape.to_s[/\Aobject:(.+)\z/, 1]&.split("::")&.last
        return Call(ConstPath(type), :new, *values) if type

        values.first
      end

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
            member = snake(text.sub(/\A_/, ""))
            IvarSet(member, member_value(member, values))
          end
        end
      end

      # A constructor is `initialize`; a destructor is `finalize`, which is the
      # name Ruby gives the hook that runs when an object goes away. Both are
      # spelled with the class's own name in C++, and the `~` is the only thing
      # that tells them apart.
      # A constructor is `initialize` and a destructor `finalize` -- through the
      # same counter as any other overload, because C++ overloads constructors
      # too and Ruby has one method per name. `SyncJournalFileRecord` declares
      # three, and emitting all three as `initialize` meant the last silently
      # replaced the other two; `SqlQuery` lost one the same way, and
      # `SyncEngine` had two `finalize`.
      def ruby_method_name(name, declarator)
        # Snaked HERE rather than in `method_name`, which has to answer with
        # the C++ spelling for the comparison on this line to recognise a
        # constructor -- `snake("Platform")` is `platform`, which is not the
        # class name, and every constructor in the tree became an ordinary
        # method of that name.
        #
        # The qualified branch of `method_name` returns the name as written,
        # so an out-of-line member kept its C++ spelling while every CALL went
        # through `snake`: `FileSystem::time_tToFileTime` was defined as
        # `time_tToFileTime` and called as `time_t_to_file_time`. The rename is
        # normally done upstream by `s-snake-identifier`, so this only showed
        # on a name that rule missed; doing it here means a miss up there can
        # no longer split a method from its callers.
        return disambiguate(snake(name), declarator) unless name == @class_name

        special = @cst.dig?(declarator, "destructor_name") ? "finalize" : "initialize"
        # A real method of that name keeps it, and the special member takes the
        # suffix -- whichever comes first in the file. `SyncEngine::finalize(bool)`
        # is called seven times and `~SyncEngine()` is called never, so renaming
        # the method would have left all seven calls pointing at the destructor.
        return "#{special}_2" if declares_method?(special)

        disambiguate(special, declarator)
      end

      # Whether the class being emitted declares an ordinary method of this
      # name. Read from the whole file up front, because the definitions are
      # emitted in source order and the collision can come either way round.
      def declares_method?(name)
        @declared ||= scan_declared_methods
        @declared.fetch(@class_name, nil)&.include?(name) || false
      end

      def scan_declared_methods
        found = {}
        @cst.descendants(@cst.root).each do |node|
          next unless node.kind == "function_definition"

          declarator = @cst.dig(node, "function_declarator", field: :declarator)
          next if declarator.nil? || @cst.dig?(declarator, "destructor_name")

          plain = method_name(declarator)
          next if plain.nil? || plain == definition_scope(node)

          (found[definition_scope(node)] ||= Set.new) << plain
        end
        found
      end

      # C++ overloads on the parameter list; Ruby has one method per name.
      #
      # `wipeErrorBlacklistEntry(file)` and `wipeErrorBlacklistEntry(file,
      # category)` would collide, so the second takes the name of the argument
      # that distinguishes it -- which is what the golden calls it.
      #
      # Counted PER CLASS. owncloudpropagator.cpp defines five classes and four
      # of them override `scheduleSelfOrChild`, which a file-wide count turned
      # into `schedule_self_or_child_2`, `_3` and `_4` -- they are not
      # overloads of each other, they are overrides.
      def disambiguate(name, declarator)
        seen = ((@method_names ||= {})[@class_name] ||= {})
        count = seen[name] = seen.fetch(name, 0) + 1
        return name if count == 1

        extra = @cst.named(@cst.field(declarator, :parameters)).last
        tail = extra && @cst.dig(extra, "identifier", field: :declarator)
        candidate = tail ? "#{name}_with_#{snake(@cst.text(tail))}" : "#{name}_#{count}"
        # The SUFFIXED name is counted too. Five of `SimpleNetworkJob`'s
        # constructors end in `QObject *parent`, so the last parameter did not
        # separate them: all five came out `initialize_with_parent` and four
        # were silently replaced by the fifth.
        taken = seen[candidate] = seen.fetch(candidate, 0) + 1
        taken == 1 ? candidate : "#{candidate}_#{taken}"
      end

      # The C++ operators Ruby spells the same way, plus the two it does not.
      #
      # A MEMBER operator -- `bool Capabilities::operator==(const Capabilities
      # &other) const` -- has an `operator_name` where a method has an
      # identifier, so `method_name` returned nothing and the emitter wrote
      # `def (other)`. That does not parse, so rubocop corrected nothing in the
      # file. The free two-argument form is `operator_equality`'s instead,
      # because there the left operand has to become the receiver.
      OPERATORS = {
        "operator==" => "==", "operator!=" => "!=", "operator<" => "<",
        "operator>" => ">", "operator<=" => "<=", "operator>=" => ">=",
        "operator+" => "+", "operator-" => "-", "operator*" => "*",
        "operator/" => "/", "operator%" => "%", "operator[]" => "[]",
        "operator<=>" => "<=>", "operator!" => "!", "operator()" => "call",
        "operator<<" => "<<", "operator bool" => "truthy?"
      }.freeze

      def method_name(declarator)
        qualified = @cst.dig(declarator, "qualified_identifier", field: :declarator)
        if qualified
          name = @cst.dig(qualified, "identifier")
          return @cst.text(name) if name

          operator = @cst.dig(qualified, "operator_name")
          return operator_name(operator) if operator
        end

        operator = @cst.child(declarator, "operator_name", field: :declarator)
        return operator_name(operator) if operator

        plain = @cst.dig(declarator, "identifier", "field_identifier", field: :declarator)
        plain && snake(@cst.text(plain))
      end

      def operator_name(node)
        text = @cst.text(node).gsub(/\s+/, " ").strip
        OPERATORS.fetch(text) { snake(text.sub(/\Aoperator\s*/, "")) }
      end

      def parameters(declarator, definition = nil)
        list = @cst.field(declarator, :parameters)
        @cst.named(list).filter_map do |param|
          case param.kind
          when "parameter_declaration"
            name = @cst.dig(param, "identifier", field: :declarator)
            next "_" if name.nil?

            # Through `local_name`, the same as every mention of the name in
            # the body. `QString Utility::escape(const QString &in)` emitted
            # `def escape(in)` -- `in` is a Ruby keyword -- while the body used
            # the renamed `in_`, so the signature and its uses disagreed and
            # the file did not parse.
            text = local_name(@cst.text(name))
            unused?(definition, @cst.text(name)) ? "_#{text}" : text
          when "variadic_parameter_declaration"
            "*#{local_name(@cst.text(@cst.dig(param, "identifier", field: :declarator)))}"
          end
        end
      end

      # A parameter the body never mentions.
      #
      # Ruby marks one with a leading underscore, and `Q_UNUSED(x)` -- which
      # 02_prepare.py leaves and the emitter drops -- is the C++ saying the
      # same thing. rubocop reports this as Lint/UnusedMethodArgument but will
      # not correct it under `-A`, so it is done here.
      def unused?(definition, name)
        return false if definition.nil?

        # The WHOLE definition, not just the body: a constructor's parameters
        # are used by its member-initialiser list and nowhere else.
        #
        # A mention inside `Q_UNUSED(x)` does not count -- that call is the C++
        # saying the parameter is unused, and the emitter drops it.
        @cst.descendants(definition).none? do |node|
          next interpolates?(node, name) if STRING_KINDS.include?(node.kind)
          next false unless %w[identifier field_identifier].include?(node.kind)
          next false unless @cst.text(node) == name
          # Its own declaration is not a use.
          next false if @cst.within?(node, "parameter_declaration")

          !unused_marker?(node)
        end
      end

      STRING_KINDS = %w[string_literal raw_string_literal concatenated_string].freeze

      # A use that 04_interp.yml has already folded into a string.
      #
      # `tr("»%1« renamed to »%2«").arg(file, renameTarget)` becomes a literal
      # carrying `#{file}` and `#{rename_target}`, so by the time the emitter
      # sees the body the parameter appears only as text inside it. Scanning
      # for identifiers alone called it unused, renamed it to `_rename_target`,
      # and left the interpolation referring to a name that no longer existed
      # -- which unparser then refused to round trip.
      def interpolates?(node, name)
        text = @cst.text(node)
        text.scan(/\#\{([^}]*)\}/).any? { |(inner)| inner.match?(/\b#{Regexp.escape(name)}\b/) }
      end

      def unused_marker?(node)
        at = node.parent
        while at
          if at.kind == "call_expression"
            callee = @cst.field(at, :function)
            return true if callee && DROPPED.include?(@cst.text(callee))
          end
          at = at.parent
        end
        false
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
      # `constexpr int retrySyncLimitC = 3;` at namespace scope -> a constant on
      # the class, named the way Ruby names one.
      # The parens around a constant's value group nothing once it is an
      # assignment, and the golden drops them -- `MINIMUM_FILE_AGE_FOR_UPLOAD =
      # 2`, from `SyncEngine::minimumFileAgeForUpload(2s)`.
      def ungrouped(value)
        inner = value && @cst.named(value).first
        case value&.kind
        # `seconds SyncEngine::minimumFileAgeForUpload(2s)` initialises with a
        # constructor's argument list, not with an `=`, and the list is the
        # init_declarator's `value`. Emitting it whole gave
        # `MINIMUM_FILE_AGE_FOR_UPLOAD = (2)`.
        when "argument_list" then @cst.named(value).one? ? inner : value
        # A LONE literal only: `GET_MAX_BLACKLIST_TIME = (24 * 3600)` keeps its
        # parens in the golden.
        when "parenthesized_expression"
          inner && inner.kind.end_with?("_literal") ? inner : value
        else value
        end
      end

      # A C++ special member the compiler writes:
      #
      #   SyncJournalFileRecord::~SyncJournalFileRecord() = default;
      #   SyncJournalFileRecord(const SyncJournalFileRecord &other) = default;
      #   SyncJournalFileRecord &operator=(const SyncJournalFileRecord &) = default;
      #
      # There is no body to carry across and Ruby has the behaviour already, so
      # it emits nothing. `= delete` likewise: it REMOVES a member, and Ruby
      # has nothing to remove.
      #
      # Without this the declaration read as a constant whose name came out of
      # the parameter list and whose value was the keyword: `OTHER = default`.
      def defaulted?(value)
        !value.nil? && value.kind == "identifier" &&
          %w[default delete].include?(@cst.text(value))
      end

      def namespace_constant(node)
        init = @cst.child(node, "init_declarator", field: :declarator)
        name = init && @cst.dig(init, "identifier")
        value = init && @cst.field(init, :value)
        return [] if name.nil? || value.nil?
        return [] if defaulted?(value)
        return [] if orphaned?(@cst.text(name))

        @constants << @cst.text(name)
        [Constant(snake(@cst.text(name)).upcase, expr(ungrouped(value)))]
      end

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

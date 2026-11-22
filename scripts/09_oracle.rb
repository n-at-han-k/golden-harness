#!/usr/bin/env ruby
# frozen_string_literal: true

# The type oracle: what the syntax cannot tell you, asked of a real compiler.
#
# ast-grep's docs are explicit that it will not answer these questions --
# advanced/faq.md, "Does ast-grep support some advanced static analysis? Short
# answer: NO", listing scope analysis and type information among the things it
# does not do -- and tree-sitter is in the same position. Both see one
# translation unit's syntax; neither resolves a name against the headers.
#
# So every such decision used to be approximated syntactically, and the
# approximations overlapped and fought. These are the ones that bit:
#
#   PreparedSqlQueryManager::DeleteDownloadInfoQuery  enum constant, or method?
#   QVector<T> v; / QSet<T> s; / QString s;           [] or Set.new or ""?
#   SqlQuery query(db);                               constructor, or function?
#   static / namespace { }                            private, or public?
#   !autotestFailCounter                              integer, or pointer?
#
# libclang answers all five, because it has read the headers.
#
# The facts are ADVISORY. A file whose headers do not resolve still produces an
# AST, just a smaller one, so the emitter treats a missing fact as "not known"
# and falls back to its own reading rather than to a wrong answer.
#
# Usage: 09_oracle.rb <source-under-02-input> <facts.json>

require "ffi/clang"
require "json"
require "set"

HERE = File.expand_path(__dir__)
ROOT = File.expand_path("..", HERE)

# The include roots a translation unit needs: the input tree itself, by every
# spelling its sources use, then the system roots nix put in the environment.
# Qt is included as <QObject>, so each Qt* module directory is a root of its
# own. Lifted from ../script.rb, which established this recipe.
def include_args
  input = File.join(ROOT, "02-input")
  project = [input, *Dir.glob("#{input}/**/*").select { File.directory?(_1) }]
  project << File.join(HERE, "clang")

  system_roots = ENV.fetch("OPENCLOUD_INCLUDE_ROOTS", "").split(":").reject(&:empty?)
  system_roots += system_roots.flat_map { Dir.glob("#{_1}/Qt*") }

  project.map { "-I#{_1}" } + system_roots.map { "-isystem#{_1}" }
end

ARGS = ["-xc++", "-std=c++20", "-stdlib=libc++", *include_args].freeze

# The same spelling the pipeline gives a lowercase-initial name, so a fact
# recorded here can still be found after 03_simplify.yml has renamed it.
# PascalCase is left alone, by that rule and by this one alike.
def snake(name)
  return name unless name.match?(/[A-Z]/)
  return name unless name.match?(/[a-z]/)

  name.gsub(/(?<=.)([A-Z])/) { "_#{::Regexp.last_match(1)}" }.downcase
end

# What a declared type means for an empty Ruby value.
#
# Only the shape is recorded, not the C++ type: the emitter needs to know that
# `QVector<SyncJournalFileRecord>` starts life as `[]`, not what it holds.
CONTAINERS = {
  "QVector" => "array", "QList" => "array", "QStringList" => "array",
  "QByteArrayList" => "array", "vector" => "array", "std::vector" => "array",
  # QStack and QQueue derive from QVector and QList: a Ruby array does both.
  "QStack" => "array", "QQueue" => "array", "deque" => "array",
  "std::deque" => "array", "stack" => "array", "std::stack" => "array",
  "QSet" => "set", "set" => "set", "std::set" => "set",
  "QMap" => "hash", "QHash" => "hash", "map" => "hash",
  "unordered_map" => "hash", "std::map" => "hash",
  "QString" => "string", "QByteArray" => "string", "std::string" => "string"
}.freeze

INTEGRAL = %i[
  type_int type_uint type_long type_ulong type_longlong type_ulonglong
  type_short type_ushort type_schar type_uchar type_char_s type_char_u
  type_float type_double type_longdouble type_enum
].freeze

def shape_of(type)
  return nil if type.nil?

  # Through the typedef. `quint64` is Qt's name for an unsigned long long, and
  # its own kind is `typedef`, so without this the integral test never fires
  # and `!inode` stayed `!inode` instead of `inode == 0`.
  type = canonical(type)
  spelling = type.spelling.to_s.sub(/\Aconst\s+/, "").sub(/\s*[&*]+\z/, "")
  base = spelling[/\A([A-Za-z_:][\w:]*)/, 1]
  # A callable parameter. `rowCallback(rec)` reads as a method call in Ruby and
  # has to be `rowCallback.call(rec)`; nothing in the syntax says which, but
  # the declared type does.
  return "proc" if base == "std::function" || base == "function"
  return CONTAINERS[base] if base && CONTAINERS.key?(base)
  return "bool" if type.kind == :type_bool
  return "int" if INTEGRAL.include?(type.kind)
  return "object:#{base}" if base && base.match?(/\A[A-Z]/)

  nil
end

def canonical(type)
  resolved = type.canonical
  resolved.nil? || resolved.kind == :type_invalid ? type : resolved
rescue NoMethodError
  type
end

facts = {
  "enum_constants" => {},   # short name  -> owning enum
  "records" => [],          # class / struct / union names
  "internal" => [],         # functions with internal linkage -> private
  "shapes" => {},           # local name  -> empty-value shape
  "integers" => [],         # names of integral type -> `!x` is `x == 0`
  "locals" => [],           # function::name -> a local, not a member
  "enum_types" => [],       # an enum's own name: `LogStatus s(X)` constructs nothing
  "scalar_types" => [],     # a typedef over a number: `qint64(x)` converts nothing
  "dead" => []              # a free function nothing can reach -> not emitted
}

# The three sets `dead` is worked out from, which the walk fills as it goes.
free_definitions = {}       # spelling -> true, a free function DEFINED here
declared_elsewhere = {}     # spelling -> true, so a header publishes it
referenced = {}             # spelling -> true, so something calls it

source = ARGV[0]
target = ARGV[1]
abort "usage: 09_oracle.rb <source> <facts.json>" if source.nil? || target.nil?

translation_unit = FFI::Clang::Index.new.parse_translation_unit(source, ARGS)

errors = translation_unit.diagnostics.count { %i[error fatal].include?(_1.severity) }

# Internal linkage, which is what decides `private`.
#
# It covers both spellings at once -- a `static` function and one inside an
# anonymous `namespace { }` -- because that is what linkage MEANS, and it reads
# the class declaration in the header too, so a method declared `static` there
# is caught even though the .cpp definition cannot repeat the keyword.
def internal?(cursor)
  cursor.linkage == :internal
rescue NoMethodError
  false
end

# The function a cursor sits in, by its own name, so a local can be keyed
# against it. Walks the semantic parents rather than the lexical ones, which is
# what puts `SyncJournalDb::checkConnect`'s locals under `check_connect`.
def enclosing_function(cursor)
  at = cursor.semantic_parent
  while at
    return at.spelling.to_s if %i[cursor_function cursor_cxx_method cursor_constructor
                                  cursor_destructor cursor_function_template].include?(at.kind)

    break if at.kind == :cursor_translation_unit

    at = at.semantic_parent
  end
  nil
rescue NoMethodError
  nil
end

# A function body in another file, which there is no reason to walk into.
#
# The oracle wants every header's ENUMS and RECORDS, so the walk cannot be
# confined to the main file -- but it does not want their statements, and Qt's
# inline and template bodies hold millions of references. Descending into them
# made this pass take minutes; pruning them brings it back to seconds.
BODIES = %i[
  cursor_function cursor_cxx_method cursor_constructor cursor_destructor
  cursor_function_template cursor_conversion_function
].freeze

# What a FREE function hangs off: nothing, or a namespace. A method hangs off
# its class, and is reached through it.
OWNERLESS = %i[cursor_translation_unit cursor_namespace].freeze

def prune?(cursor)
  BODIES.include?(cursor.kind) && !cursor.location.from_main_file?
end

def visit(cursor, facts, &block)
  cursor.visit_children do |child, _parent|
    block.call(child)
    visit(child, facts, &block) unless prune?(child)
    :continue
  end
end

visit(translation_unit.cursor, facts) do |cursor|
  name = cursor.spelling.to_s
  next if name.empty?

  case cursor.kind
  when :cursor_enum_constant_decl
    # Both spellings: the short name, for an unqualified mention, and the
    # qualified one, because a short name can collide with a type elsewhere in
    # the tree and `Scope::Name` is the form that cannot.
    parent = cursor.semantic_parent&.spelling.to_s
    facts["enum_constants"][name] = parent
    facts["enum_constants"]["#{parent}::#{name}"] = parent unless parent.empty?
  when :cursor_class_decl, :cursor_struct_decl, :cursor_union_decl, :cursor_class_template
    facts["records"] << name
  when :cursor_enum_decl
    facts["enum_types"] << name
  when :cursor_typedef_decl, :cursor_type_alias_decl
    # `qint64` is Qt's name for a long long, and `qint64(60 * 60)` is a cast
    # written as a call. Ruby has one integer type, so it carries nothing.
    kind = (canonical(cursor.type)&.kind rescue nil)
    facts["scalar_types"] << name if INTEGRAL.include?(kind) || kind == :type_bool
    # An alias over a CLASS is constructible under its own name:
    # `using SyncFileItemPtr = QSharedPointer<SyncFileItem>` makes
    # `SyncFileItemPtr(x)` a construction, which Ruby spells `.new`.
    facts["records"] << name if %i[type_record type_unexposed].include?(kind)
  when :cursor_function, :cursor_cxx_method
    # A declaration in a HEADER means the function is this library's published
    # API, so it is kept even with no caller in the file -- it is reached from
    # a translation unit the oracle is not looking at.
    unless cursor.location.from_main_file?
      declared_elsewhere[name] = true
      next
    end

    facts["internal"] << snake(name) if internal?(cursor)
    # A free function, as against a method: a method is reached through its
    # class and `_syncItems`-style callers libclang resolves differently.
    # `semantic_parent` is the translation unit or a namespace for a free one.
    if cursor.kind == :cursor_function && cursor.definition?
      owner = cursor.semantic_parent&.kind
      free_definitions[name] = true if OWNERLESS.include?(owner)
    end
  when :cursor_decl_ref_expr, :cursor_member_ref_expr, :cursor_call_expr
    # Every mention of a name in the main file. The BODIES prune keeps this
    # cheap: Qt's inline bodies are never descended into.
    referenced[name] = true if cursor.location.from_main_file?
  when :cursor_variable, :cursor_field_decl, :cursor_parm_decl
    # This file's own names, plus any GLOBAL -- `autotestFailCounter` is an
    # `extern int` declared in a header, and its type is the fact that decides
    # whether `!autotestFailCounter` means `== 0`.
    #
    # A global is cheap to spot -- it has no enclosing function -- and there
    # are few of them. Reading types off every REFERENCE instead would also
    # have found it, and was tried: it walks every expression in every Qt
    # header and took this pass from seconds to minutes, for one name.
    scope = enclosing_function(cursor)
    next unless cursor.location.from_main_file? || scope.nil?

    scope_name = enclosing_function(cursor)
    if scope_name && cursor.kind == :cursor_variable
      # Recorded before the shape test: a lambda's type has no shape -- its
      # spelling is `(lambda at ...)` -- but `_exec` is still a local, and that
      # is what decides whether its underscore becomes an `@`.
      facts["locals"] << "#{snake(scope_name)}::#{snake(name)}"
      facts["locals"] << "#{snake(scope_name)}::#{snake(name.sub(/\A_/, ""))}"
    end

    shape = shape_of(cursor.type)
    next if shape.nil?

    # Scoped as well as bare. A name is only unique within its function --
    # `columns` is a QVector in one method and a parameter in another -- so the
    # bare key is a fallback and the scoped one is what resolves it.
    facts["shapes"][snake(name)] = shape
    facts["shapes"]["#{snake(scope)}::#{snake(name)}"] = shape if scope
    # A LOCAL, as against a member of the class. `_exec` is a local lambda and
    # the golden drops its underscore; `_dbFile` is a member and keeps it as
    # the `@`. Nothing in the spelling tells them apart.
    facts["integers"] << snake(name) if shape == "int"
  end
end

facts["records"] = facts["records"].uniq.sort
facts["internal"] = facts["internal"].uniq.sort
facts["integers"] = facts["integers"].uniq.sort
facts["locals"] = facts["locals"].uniq.sort
facts["enum_types"] = facts["enum_types"].uniq.sort
facts["scalar_types"] = facts["scalar_types"].uniq.sort

# DEAD CODE, which is what is left of the platform branches.
#
# `02_prepare` resolves `#ifdef _WIN32` away and libclang skips it for the same
# reason, so the only call to `csync_is_windows_reserved_word` is gone -- but
# its DEFINITION is not itself inside the conditional, so nothing removes it.
# With no caller in the file and no declaration in a header, nothing can reach
# it, and the constants it reads (`win_device_names`) go with it.
dead = free_definitions.keys.reject { referenced[_1] || declared_elsewhere[_1] }
facts["dead"] = dead.map { snake(_1) }.uniq.sort

facts["diagnostics"] = errors

File.write(target, JSON.pretty_generate(facts))
warn "oracle: #{facts["enum_constants"].size} enum constants, " \
     "#{facts["records"].size} records, #{facts["internal"].size} internal, " \
     "#{facts["shapes"].size} typed names, #{facts["dead"].size} unreachable, " \
     "#{errors} diagnostics"

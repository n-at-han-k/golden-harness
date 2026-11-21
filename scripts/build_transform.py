#!/usr/bin/env python3
"""Generate golden-harness/transform.yml -- the single C++ -> Ruby rule.

Why one rule and not a series of passes
---------------------------------------
Every ast-grep pass needs parseable C++ on its input. The moment a pass emits
Ruby, the file stops being C++ and no later pass can see inside it. This is not
theoretical -- it is the bug that made an earlier three-pass emitter silently
produce nothing:

    pass 20 rewrote `// comment` to `# comment`
    ... but `#` at the start of a line is a PREPROCESSOR DIRECTIVE in C++,
    so the file filled with ERROR nodes
    ... so pass 21 (methods) matched nothing at all, and the bodies came out
    as raw C++ with braces and semicolons intact

`require_relative "discovery.h"` is not valid C++ either, so include rewriting
has the same problem. Both have to happen in the same rewrite as everything
else.

So: ONE rule rooted at translation_unit, with every construct as a rewriter.
Precedence is then well defined (list order decides ties, outer match wins) and
exactly one rewrite is applied to the file.

Why generated rather than hand-written
--------------------------------------
Statement rewriters must be TIERED by nesting depth. ast-grep has no cycle
guard, so a rewriter that lists itself overflows the stack -- observed as
`thread 'main' has overflowed its stack`. Each tier delegates to the next, which
terminates. Writing seven near-identical tiers by hand invites drift, so they
are generated.

Two invariants the generated rules must preserve:

  * Every rewriter is constrained with `inside: {kind: ...}` (immediate parent,
    no stopBy). Without it a nested statement matches at every enclosing level
    and the overlapping edits lose content.
  * NO rewriter uses `joinBy`. Per guide/rewrite/rewriter.md, ast-grep's
    default is to "generate the new rewritten string by replacing the text in
    the matched sub nodes" -- that is, the surrounding text is PRESERVED and
    only matches are substituted. `joinBy` switches to joining the matches and
    throwing the rest away.

    An earlier version set `joinBy: "\n"` everywhere, which silently deleted
    every statement, comment and blank line that no rewriter happened to match,
    and needed a CXX_UNMAPPED catch-all to notice. Dropping joinBy removes both
    the data loss and the need for the catch-all: an unhandled construct simply
    stays as C++ in the output, where it is obvious.

Usage:
    python3 golden-harness/build_transform.py
"""
from __future__ import annotations

import pathlib

HERE = pathlib.Path(__file__).resolve().parent
# Statement nesting depth. Measured on the simplified C++, not guessed: the
# deepest statement in discovery.cpp sits 9 tiers inside its method body. It is
# deeper than the source looks because three normalisations each add a level --
# `else if` -> `else { if }`, `switch` -> case, and a braced case body -- so a
# plain read of the C++ understates it. The cost of headroom is generated YAML
# and nothing else; the cost of too little is statements silently left as C++
# at the deepest tier, which is what capped handle_excluded at tier 7.
DEPTH = 12

# Order matters: the idiom rules come FIRST so they win over the generic
# declaration and expression rules, which would otherwise match the same nodes.
# s-log precedes s-expr: a `qCInfo(lcDisco) << ...` statement is also an
# expression_statement, and the first matching rewriter in the list wins.
STMT_LEAVES = ["s-struct", "s-map-decl", "s-assert", "s-unreachable",
               "s-decl", "s-decl-bare", "s-log", "s-expr", "s-return",
               "s-return-void", "s-next", "s-break"]
# s-lambda-call is a BLOCK, not a leaf: it rewrites the lambda's body through
# {nxt}, so it can only exist while a next tier does. It must also come FIRST,
# ahead of s-expr -- a call with a trailing lambda is also an
# expression_statement, and the first matching rewriter in the list wins.
# s-case-pair and s-case-absorbed precede s-case: a fall-through label pair is
# also a plain case, and the first matching rewriter in the list wins.
STMT_BLOCKS = ["s-if-else", "s-if", "s-while", "s-foreach", "s-for",
               "s-switch", "s-case-pair", "s-case-absorbed", "s-case",
               "s-default", "s-block"]


def stmt_ids(tier: int, leaves_only: bool) -> str:
    names = STMT_LEAVES + ([] if leaves_only else STMT_BLOCKS) + ["s-comment"]
    return "[" + ", ".join(f"{n}-{tier}" for n in names) + "]"


def statement_tier(tier: int) -> str:
    """One tier of statement rewriters, delegating blocks to tier+1."""
    t = f"-{tier}"
    last = tier >= DEPTH
    nxt = stmt_ids(tier + 1, leaves_only=(tier + 1 >= DEPTH)) if not last else None
    inside = "inside: { kind: compound_statement }"
    # Expression-position rewriters. l-call only exists while a next tier does,
    # since it rewrites the lambda body through it.
    expr_rw = (f"[l-iife-{tier}, l-lambda-arg-{tier}, l-lambda0-arg-{tier}, "
               f"l-lambda-{tier}, l-lambda0-{tier}, l-call-brace-{tier}, "
               f"l-new-{tier}, l-new0-{tier}, l-brace-init-{tier}, "
               f"l-addr-{tier}, l-lcall-{tier}, l-lbare-{tier}, "
               f"l-enum-{tier}]"
               if not last
               else f"[l-iife-{tier}, l-new-{tier}, l-new0-{tier}, "
                    f"l-brace-init-{tier}, l-addr-{tier}, l-lcall-{tier}, "
                    f"l-lbare-{tier}, l-enum-{tier}]")

    out = f"""  # ---- statement tier {tier} ----------------------------------------------
  # `struct Entries {{ A a; B b; }};` -> `Entries = Struct.new(:a, :b, keyword_init: true)`
  #
  # Emitted HERE, not in the simplify stage: the fix is Ruby, so producing it
  # earlier stops the file parsing as C++ and this rule's own catch-all then
  # swallows it. keyword_init: true is what makes `Entry.new` with no arguments
  # work, which the golden relies on.
  - id: s-struct-field{t}
    rule:
      kind: field_declaration
      inside: {{ kind: field_declaration_list }}
      all:
        - has: {{ field: declarator, kind: field_identifier, pattern: $SFN }}
        - not: {{ has: {{ field: declarator, kind: function_declarator }} }}
    fix: ":$SFN"
  - id: s-struct{t}
    rule:
      any:
        - kind: struct_specifier
        - kind: class_specifier
      inside: {{ kind: compound_statement, stopBy: end }}
      all:
        - has: {{ field: name, kind: type_identifier, pattern: $STN }}
        - has: {{ field: body, kind: field_declaration_list, pattern: $STB }}
        - not: {{ has: {{ stopBy: end, kind: function_declarator }} }}
    transform:
      # joinBy IS wanted here, as for MARGS: the text being discarded is the
      # braces and the C++ field declarations, which is the point.
      SFIELDS:
        rewrite:
          rewriters: [s-struct-field{t}]
          source: $STB
          joinBy: ",\\n"
    fix: |-
      $STN = Struct.new(
      $SFIELDS,
      keyword_init: true
      )
  # `std::map<K, V> name;` -> a Hash that default-constructs its values.
  #
  # The block form is required, not cosmetic: C++ `map[k]` DEFAULT-CONSTRUCTS a
  # missing value, which is what lets `entries[e.name()].serverEntry = e` work
  # on an absent key. A plain `{{}}` returns nil and raises.
  # Same rule as s-struct{t} but emitting nothing: used by the body pass, so
  # the declaration appears only once, above the def.
  - id: s-struct-drop{t}
    rule:
      any:
        - kind: struct_specifier
        - kind: class_specifier
      inside: {{ kind: compound_statement, stopBy: end }}
      all:
        - has: {{ field: name, kind: type_identifier }}
        - has: {{ field: body, kind: field_declaration_list }}
        - not: {{ has: {{ stopBy: end, kind: function_declarator }} }}
    fix: ""
  - id: s-map-decl{t}
    rule:
      kind: declaration
      {inside}
      all:
        # `std::map<K, V> name;` parses as a qualified_identifier CONTAINING a
        # template_type -- not as a template_type -- and its arguments are
        # type_descriptor nodes wrapping the type, so the value type is the
        # SECOND type_descriptor. Matching `field: type, kind: template_type`
        # therefore never fired and `entries` fell through as `entries = nil`.
        # The template_type's own name is `map`, without the `std::` scope.
        - has:
            field: type
            stopBy: end
            kind: template_type
            all:
              - has:
                  field: name
                  kind: type_identifier
                  regex: '^(map|unordered_map|QMap|QHash)$'
              - has:
                  field: arguments
                  kind: template_argument_list
                  has:
                    kind: type_descriptor
                    nthChild: 2
                    has: {{ field: type, kind: type_identifier, pattern: $VT }}
        - has: {{ field: declarator, stopBy: end, kind: identifier, pattern: $MN }}
    fix: |-
      $MN = Hash.new do |hash, key|
      hash[key] = $VT.new
      end
  # `new Foo(a, b)` -> `Foo.new(a, b)`.
  #
  # An emitter rewriter rather than a C++ -> C++ rule, because `Foo.new(a, b)`
  # is not C++ and would stop the file parsing for every later rule. Kept in
  # expr_rw at EVERY tier, including the last, since a `new` can appear in the
  # deepest expression.
  # `connect(job, &RequestEtagJob::finishedSignal, this, slot)`
  # -> `connect(job, RequestEtagJob.finished_signal, this, slot)`
  #
  # Ruby allows `&` on the LAST argument only, where it means block-pass.
  # Anywhere else the parse fails outright with "unexpected argument after a
  # block argument", which is what two Qt `connect` calls in discovery.cpp did.
  #
  # So the `&` is dropped only when the argument is not last -- the golden
  # keeps it where it IS last, as in
  # `QTimer.single_shot(0, @discovery_data, &DiscoveryPhase.schedule_more_jobs)`,
  # and `nthChild: {{ position: 1, reverse: true }}` is what tells the two apart.
  #
  # What a mid-list Qt signal reference SHOULD become is a convention decision,
  # not a mechanical one; this rule only makes it parse.
  # Invoking a lambda: `finalize(path, x)` -> `finalize.call(path, x)`.
  #
  # In Ruby a bare `finalize(...)` is a METHOD call, so the lambda is never
  # reached -- rubocop reports the assignment as a useless one and the call
  # raises NoMethodError. The golden spells it `.call`.
  #
  # Which names are lambdas is cross-statement knowledge, and the metavariable
  # is what carries it: $LNAME appears both on the call's function and on an
  # init_declarator inside the enclosing function_definition, and ast-grep
  # unifies the two, so only a name actually bound to a lambda in this method
  # is rewritten. An ordinary method call with the same shape is left alone.
  - id: l-lcall{t}
    rule:
      kind: call_expression
      all:
        - has: {{ field: function, kind: identifier, pattern: $LNAME }}
        - has: {{ field: arguments, kind: argument_list, pattern: $LCARGS }}
        - inside:
            stopBy: end
            kind: function_definition
            has:
              stopBy: end
              kind: init_declarator
              all:
                - has: {{ field: declarator, kind: identifier, pattern: $LNAME }}
                - has: {{ field: value, kind: lambda_expression }}
    fix: "$LNAME.call$LCARGS"
  # The same lambda mentioned with no arguments at all -- `post_process_server_new;`
  # as a statement of its own, which in C++ is a no-op expression but in the
  # source means the call. `not: inside init_declarator` keeps the rule off the
  # lambda's own binding.
  - id: l-lbare{t}
    rule:
      kind: identifier
      pattern: $LBNAME
      all:
        - inside: {{ kind: expression_statement }}
        - not: {{ inside: {{ kind: init_declarator }} }}
        - inside:
            stopBy: end
            kind: function_definition
            has:
              stopBy: end
              kind: init_declarator
              all:
                - has: {{ field: declarator, kind: identifier, pattern: $LBNAME }}
                - has: {{ field: value, kind: lambda_expression }}
    fix: "$LBNAME.call"
  # A qualified enum constant becomes a bare symbol of its last segment:
  # `SyncFileItem::Excluded` -> `:excluded`, `Vfs::Mode::Off` -> `:off`,
  # `Qt::CaseInsensitive` -> `:case_insensitive`.
  #
  # Read off the golden, which keeps no `Class::Constant` at all, and applies
  # it in every position -- assignment, comparison and argument alike
  # (`.ends_with(".eml", :case_insensitive)`).
  #
  # `A::B::C` nests, with the final segment as the deepest `name`, so the
  # search is `field: name` with `stopBy: end`.
  #
  # The PascalCase test on that segment is what keeps this off everything else:
  # `std::filesystem::directory_entry` ends lowercase and stays, and so do
  # qualified METHOD calls -- `QTimer::singleShot`, `Utility::fsCasePreserving`
  # -- which begin lowercase and are handled as `::` -> `.` instead.
  - id: l-enum{t}
    rule:
      kind: qualified_identifier
      has:
        field: name
        stopBy: end
        kind: identifier
        pattern: $ENAME
        regex: '^[A-Z][A-Za-z0-9]*$'
    transform:
      ESYM:
        convert: {{ source: $ENAME, toCase: snakeCase }}
    fix: ":$ESYM"
  - id: l-addr{t}
    rule:
      kind: pointer_expression
      regex: '^&'
      inside: {{ kind: argument_list }}
      not: {{ nthChild: {{ position: 1, reverse: true }} }}
      has: {{ field: argument, pattern: $AV }}
    fix: "$AV"
  - id: l-new{t}
    rule:
      kind: new_expression
      all:
        - has: {{ field: type, pattern: $NT }}
        - has: {{ field: arguments, kind: argument_list, pattern: $NA }}
    fix: "$NT.new$NA"
  # `new Foo` with no argument list.
  - id: l-new0{t}
    rule:
      kind: new_expression
      has: {{ field: type, pattern: $NT0 }}
      not: {{ has: {{ field: arguments, kind: argument_list }} }}
    fix: "$NT0.new"
  # `Foo{{a, b}}` -- C++ brace initialisation -- -> `Foo.new(a, b)`.
  # The braces belong to the initializer_list node, so they are stripped from
  # the captured text rather than matched away.
  - id: l-brace-init{t}
    rule:
      kind: compound_literal_expression
      all:
        - has: {{ field: type, pattern: $BT }}
        - has: {{ field: value, kind: initializer_list, pattern: $BV }}
    transform:
      BARGS:
        replace: {{ source: $BV, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: "$BT.new($BARGS)"
  - id: l-iife{t}
    rule:
      kind: call_expression
      has:
        field: function
        kind: lambda_expression
        has:
          field: body
          kind: compound_statement
          has:
            kind: return_statement
            has: {{ stopBy: end, pattern: $IIFE }}
    fix: "$IIFE"
  # `OC_ASSERT(cond)` -> `unless cond / raise / end`
  #
  # The C++ macro aborts when the condition is FALSE, so the guard is negated.
  # `if cond / raise / end` raises exactly when the assertion HOLDS.
  #
  # Emitted here, not in the simplify stage: the fix is Ruby, and producing it
  # earlier stops the file parsing as C++. Listed ahead of s-expr because an
  # OC_ASSERT call is also an expression_statement and the first match wins.
  - id: s-assert{t}
    rule:
      kind: expression_statement
      {inside}
      has:
        stopBy: end
        kind: call_expression
        all:
          - has:
              field: function
              kind: identifier
              regex: '^(OC_ASSERT|OC_ASSERT_X|OC_ENFORCE|OC_ENFORCE_X|Q_ASSERT|Q_ASSERT_X)$'
          - has:
              field: arguments
              kind: argument_list
              has: {{ pattern: $ACOND }}
    fix: |-
      unless $ACOND
      raise
      end
  # `Q_UNREACHABLE();` marks a branch that cannot be taken -- there is no
  # condition to test, so it is a bare `raise` rather than s-assert's
  # `unless ... raise ... end`. Listed with the other macro rules and ahead of
  # s-expr, which would otherwise emit the call verbatim.
  - id: s-unreachable{t}
    rule:
      kind: expression_statement
      {inside}
      has:
        stopBy: end
        kind: call_expression
        has:
          field: function
          kind: identifier
          regex: '^(Q_UNREACHABLE|OC_UNREACHABLE)$'
    fix: "raise"
  - id: s-decl{t}
    rule:
      kind: declaration
      {inside}
      has:
        field: declarator
        kind: init_declarator
        all:
          - has: {{ field: declarator, pattern: $DN }}
          - has: {{ field: value, pattern: $DVR }}
    transform:
      # The initialiser is rewritten too: `const bool isHidden = [&]{{...}}()`
      # keeps its lambda otherwise.
      DV_NL:
        rewrite: {{ rewriters: {expr_rw}, source: $DVR }}
      # A C++ line wrap inside the expression survives into the Ruby, where it
      # is a syntax error for an operator continuation and merely ugly for a
      # method one (`item.error_string = "..."` then `.arg(x)` on the next
      # line). Both are pulled back up. A `.` continuation takes no space; an
      # operator one takes one. Newlines inside a block are left alone -- the
      # patterns require an operator or a dot right after the break.
      DV_DOT:
        replace: {{ source: $DV_NL, replace: '\\s*\\n\\s*\\.', by: '.' }}
      DV:
        replace: {{ source: $DV_DOT, replace: '\\s*\\n\\s*(?<OP>&&|\\|\\|)', by: ' $OP' }}
    fix: "$DN = $DV"
  - id: s-decl-bare{t}
    rule:
      kind: declaration
      {inside}
      all:
        - has: {{ field: declarator, kind: identifier, pattern: $DNB }}
        - not: {{ has: {{ field: declarator, kind: init_declarator }} }}
    fix: "$DNB = nil"
  # `qCInfo(lcDisco) << u"X" << a << b` -> `Log.info(lcDisco) {{ "X #{{a}} #{{b}}" }}`
  #
  # The chain is a left-nested binary_expression, so it is folded with a
  # rewriter over its operands and `joinBy` -- which is the one place joinBy IS
  # wanted, because what it discards is the `<<` tokens.
  #
  # Each operand becomes either literal text (a string_literal, with its quotes
  # and any `u` prefix stripped) or an interpolation. The `qCInfo(lcDisco)` head
  # rewrites to nothing, and g-head is listed FIRST so it claims that call
  # before g-val can wrap it in `#{{}}`.
  #
  # This replaced a Python regex that scanned for `<<` in text. The regex was
  # newline-bounded, so it folded only the first line of a wrapped chain and
  # left the other ten as raw C++ -- which by itself stopped the file parsing
  # as Ruby. The tree has no such problem: a chain is one node however it is
  # laid out.
  #
  # The level comes from the function name by sequential `replace`s rather than
  # a lookup table: Warning -> warn and Critical -> error are named explicitly,
  # then the `qC` prefix is dropped and the rest lowercased.
  - id: s-log{t}
    rule:
      kind: expression_statement
      {inside}
      has:
        kind: binary_expression
        pattern: $CHAIN
        has:
          stopBy: end
          kind: call_expression
          all:
            - has:
                field: function
                stopBy: end
                kind: identifier
                pattern: $LFNAME
                regex: '^qC(Info|Debug|Warning|Critical|Fatal)$'
            - has:
                field: arguments
                kind: argument_list
                has: {{ kind: identifier, pattern: $LCAT }}
    transform:
      # NO joinBy here, deliberately -- unlike every other rewrite in this
      # file. joinBy throws the unmatched text away, and the unmatched text is
      # the `<<` separators, which carry the ONE thing the tree cannot
      # otherwise tell us: where the author broke the chain. The golden keeps
      # that grouping, one Ruby string per source line, so the separators are
      # kept and then rewritten in place below.
      LRAW:
        rewrite:
          rewriters: [g-head, g-lit, g-val-paren, g-val]
          source: $CHAIN
      # g-head rewrote `qCInfo(lcDisco)` to nothing, leaving the chain's first
      # separator dangling at the front.
      LP1:
        replace: {{ source: $LRAW, replace: '^\\s*<<\\s*', by: '' }}
      # A separator the author put on a new line becomes an adjacent string
      # literal on a continuation line -- Ruby concatenates those, and it is
      # what the golden writes.
      LP2:
        replace: {{ source: $LP1, replace: '\\s*\\n\\s*<<\\s*', by: "\\" \\\\\\n\\"" }}
      # Any separator left was on the same line as its neighbours.
      # One separator space, the way QDebug streams operands. `\\s*` cannot
      # cross g-lit's `@~@` markers, so a literal's own edge spaces survive.
      LJOIN:
        replace: {{ source: $LP2, replace: '\\s*<<\\s*', by: ' ' }}
      # Markers out.
      LPARTS:
        replace: {{ source: $LJOIN, replace: '@~@', by: '' }}
      LL1:
        replace: {{ source: $LFNAME, replace: '^qCWarning$', by: 'warn' }}
      LL2:
        replace: {{ source: $LL1, replace: '^qCCritical$', by: 'error' }}
      LL3:
        replace: {{ source: $LL2, replace: '^qC', by: '' }}
      LLVL:
        convert: {{ source: $LL3, toCase: lowerCase }}
    fix: 'Log.$LLVL($LCAT) {{ "$LPARTS" }}'
  - id: s-expr{t}
    rule:
      kind: expression_statement
      {inside}
      has: {{ pattern: $EXR }}
    transform:
      # The expression is rewritten, not emitted verbatim. Without this a
      # `connect(job, &C::sig, this, [captures](args) {{ ... }})` statement came
      # through with its lambda intact -- 8 of them in discovery.cpp, and their
      # bodies account for the last of the leftover C++ braces.
      EX_NL:
        rewrite: {{ rewriters: {expr_rw}, source: $EXR }}
      # A C++ line wrap inside the expression survives into the Ruby, where it
      # is a syntax error for an operator continuation and merely ugly for a
      # method one (`item.error_string = "..."` then `.arg(x)` on the next
      # line). Both are pulled back up. A `.` continuation takes no space; an
      # operator one takes one. Newlines inside a block are left alone -- the
      # patterns require an operator or a dot right after the break.
      EX_DOT:
        replace: {{ source: $EX_NL, replace: '\\s*\\n\\s*\\.', by: '.' }}
      EX:
        replace: {{ source: $EX_DOT, replace: '\\s*\\n\\s*(?<OP>&&|\\|\\|)', by: ' $OP' }}
    fix: "$EX"
  - id: s-return{t}
    rule:
      kind: return_statement
      {inside}
      has: {{ stopBy: end, pattern: $RVR }}
    transform:
      # Rewritten, not emitted verbatim -- same reason as s-expr. A
      # `return MovePermissionResult{{a, b, c}}` kept its C++ brace
      # initialisation otherwise.
      RV_NL:
        rewrite: {{ rewriters: {expr_rw}, source: $RVR }}
      # A C++ line wrap inside the expression survives into the Ruby, where it
      # is a syntax error for an operator continuation and merely ugly for a
      # method one (`item.error_string = "..."` then `.arg(x)` on the next
      # line). Both are pulled back up. A `.` continuation takes no space; an
      # operator one takes one. Newlines inside a block are left alone -- the
      # patterns require an operator or a dot right after the break.
      RV_DOT:
        replace: {{ source: $RV_NL, replace: '\\s*\\n\\s*\\.', by: '.' }}
      RV:
        replace: {{ source: $RV_DOT, replace: '\\s*\\n\\s*(?<OP>&&|\\|\\|)', by: ' $OP' }}
    fix: "return $RV"
  - id: s-return-void{t}
    rule:
      kind: return_statement
      {inside}
      not: {{ has: {{ stopBy: end, pattern: $ANYR }} }}
    fix: "return"
  - id: s-next{t}
    rule: {{ kind: continue_statement, {inside} }}
    fix: "next"
  - id: s-break{t}
    rule: {{ kind: break_statement, {inside} }}
    fix: "break"
  # A comment inside a body. Converted HERE rather than in a separate pass,
  # because `#` at line start is a preprocessor directive to a C++ parser.
  - id: s-comment{t}
    rule:
      kind: comment
      {inside}
      pattern: $SC
    transform:
      SCB:
        replace: {{ source: $SC, replace: '(?m)^[ \\t]*(?:/\\*+|//+|\\*+/|\\*)[ \\t]?', by: '# ' }}
    fix: "$SCB"
"""
    if not last:
        out += f"""  # `f(x, [&](const Rec &rec) {{ ... }})` -> `f(x) do |rec| ... end`
  #
  # A C++ callback passed as the last argument is Ruby's trailing block. The
  # parameter name sits under a reference_declarator inside the
  # abstract_function_declarator, so the search needs stopBy: end while staying
  # scoped to the declarator field -- unscoped it finds the TYPE's identifier.
  #
  # Matches the call_expression itself, NOT an expression_statement, so it also
  # fires inside an `if` condition, which is where discovery.cpp's one lambda
  # lives.
  # One argument of the call being rewritten.
  #
  # `not: inside lambda_expression` is load-bearing. LARGS uses joinBy, which
  # collects EVERY match anywhere in the source, and the lambda being turned
  # into a block contains calls of its own -- so their arguments were being
  # joined into the outer call's argument list, which is how
  # `connect(local_job, &X.finished_fatal_error, this, msg)` grew a stray `msg`
  # taken from inside the block body.
  - id: l-arg{t}
    rule:
      inside: {{ kind: argument_list }}
      pattern: $LA
      not:
        any:
          - {{ kind: lambda_expression }}
          - {{ inside: {{ kind: lambda_expression, stopBy: end }} }}
    fix: "$LA"
  # `&Class::signal` in a non-final argument slot loses its `&`, for the reason
  # given on l-addr. Listed before l-arg so it claims the node first.
  - id: l-arg-addr{t}
    rule:
      kind: pointer_expression
      regex: '^&'
      inside: {{ kind: argument_list }}
      not:
        any:
          - {{ inside: {{ kind: lambda_expression, stopBy: end }} }}
          - {{ nthChild: {{ position: 1, reverse: true }} }}
      has: {{ field: argument, pattern: $LAA }}
    fix: "$LAA"
  # A lambda BOUND TO A NAME: `auto f = [c](A a, B b) {{ ... }};`
  # -> `f = lambda do |a, b| ... end`.
  #
  # Distinct from l-call/l-call-brace, which take a lambda passed as a call
  # ARGUMENT, and from l-iife, which takes one immediately invoked. Without
  # this, a bound lambda came through as C++ -- capture list, braces and all --
  # and took the rest of its method with it, which is where 85 of the leftover
  # brace lines in discovery.cpp came from.
  #
  # The block parameters come from the lambda's OWN declarator, so they are
  # exactly what the C++ author wrote. A Qt `connect` slot lambda declares no
  # parameters, and this correctly emits none: the slot's real arguments come
  # from the SIGNAL's declaration in another header, which this file cannot
  # see, so inventing a `|*_|` here would be a guess.
  # A lambda in ARGUMENT position: `connect(a, &C::sig, this, [c](A a) {{ ... }})`
  # -> `connect(a, &C.sig, this, lambda {{ |a| ... }})`.
  #
  # Braces, not do/end: `f(x, lambda do ... end)` binds the block to `f`, not
  # to `lambda`, which is the same trap that made s-lambda-call use braces for
  # a block inside an `if` condition.
  #
  # Listed before l-lambda so it wins for the same node -- rewriter list order
  # decides, and only the first match applies.
  - id: l-lambda-arg{t}
    rule:
      kind: lambda_expression
      inside: {{ kind: argument_list }}
      all:
        - has:
            field: declarator
            kind: abstract_function_declarator
            has:
              field: parameters
              kind: parameter_list
              pattern: $LAP
              has: {{ kind: parameter_declaration }}
        - has: {{ field: body, kind: compound_statement, pattern: $LAB }}
    transform:
      LAARGS:
        rewrite:
          rewriters: [p-named, p-unnamed, p-variadic]
          source: $LAP
          joinBy: ", "
      LARAW:
        rewrite: {{ rewriters: {nxt}, source: $LAB }}
      LABODY:
        replace: {{ source: $LARAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: |-
      lambda {{ |$LAARGS|
      $LABODY
      }}
  - id: l-lambda0-arg{t}
    rule:
      kind: lambda_expression
      inside: {{ kind: argument_list }}
      has: {{ field: body, kind: compound_statement, pattern: $LZAB }}
      not:
        has:
          field: declarator
          stopBy: end
          kind: parameter_declaration
    transform:
      LZARAW:
        rewrite: {{ rewriters: {nxt}, source: $LZAB }}
      LZABODY:
        replace: {{ source: $LZARAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: |-
      lambda {{
      $LZABODY
      }}
  - id: l-lambda{t}
    rule:
      kind: lambda_expression
      all:
        - has:
            field: declarator
            kind: abstract_function_declarator
            has:
              field: parameters
              kind: parameter_list
              pattern: $LMP
              has: {{ kind: parameter_declaration }}
        - has: {{ field: body, kind: compound_statement, pattern: $LMB }}
    transform:
      LMARGS:
        rewrite:
          rewriters: [p-named, p-unnamed, p-variadic]
          source: $LMP
          joinBy: ", "
      LMRAW:
        rewrite: {{ rewriters: {nxt}, source: $LMB }}
      LMBODY:
        replace: {{ source: $LMRAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: |-
      lambda do |$LMARGS|
      $LMBODY
      end
  # `[&] {{ ... }}` and `[&]() {{ ... }}` -- no parameters, so no block
  # parameter list. The declarator is absent in the first form and present but
  # empty in the second, which is why the test is for a parameter_declaration
  # rather than for the declarator itself.
  - id: l-lambda0{t}
    rule:
      kind: lambda_expression
      has: {{ field: body, kind: compound_statement, pattern: $LZB }}
      not:
        has:
          field: declarator
          stopBy: end
          kind: parameter_declaration
    transform:
      LZRAW:
        rewrite: {{ rewriters: {nxt}, source: $LZB }}
      LZBODY:
        replace: {{ source: $LZRAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: |-
      lambda do
      $LZBODY
      end
  - id: l-call{t}
    rule:
      kind: call_expression
      all:
        - has: {{ field: function, pattern: $LFN }}
        - has:
            field: arguments
            kind: argument_list
            pattern: $LAL
            has:
              kind: lambda_expression
              all:
                - has:
                    field: declarator
                    stopBy: end
                    kind: identifier
                    pattern: $LP
                - has: {{ field: body, kind: compound_statement, pattern: $LB }}
    transform:
      LARGS:
        rewrite:
          rewriters: [l-arg-addr{t}, l-arg{t}]
          source: $LAL
          joinBy: ", "
      LBRAW:
        rewrite: {{ rewriters: {nxt}, source: $LB }}
      LBODY:
        replace: {{ source: $LBRAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: |-
      $LFN($LARGS) do |$LP|
      $LBODY
      end
  # The same conversion with BRACES, for a block inside an `if`
  # condition. `do ... end` binds to the outermost call, so its `end`
  # closes the `if` and everything after falls outside the branch;
  # `{ ... }` binds to the call it follows.
  - id: l-call-brace{t}
    rule:
      kind: call_expression
      all:
        - has: {{ field: function, pattern: $LFN }}
        - has:
            field: arguments
            kind: argument_list
            pattern: $LAL
            has:
              kind: lambda_expression
              all:
                - has:
                    field: declarator
                    stopBy: end
                    kind: identifier
                    pattern: $LP
                - has: {{ field: body, kind: compound_statement, pattern: $LB }}
    transform:
      LARGS:
        rewrite:
          rewriters: [l-arg-addr{t}, l-arg{t}]
          source: $LAL
          joinBy: ", "
      LBRAW:
        rewrite: {{ rewriters: {nxt}, source: $LB }}
      LBODY:
        replace: {{ source: $LBRAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: |-
      $LFN($LARGS) {{ |$LP|
      $LBODY
      }}
  - id: s-if-else{t}
    rule:
      kind: if_statement
      {inside}
      all:
        - has: {{ field: condition, kind: condition_clause, has: {{ pattern: $ICR }} }}
        - has: {{ field: consequence, kind: compound_statement, pattern: $IT }}
        - has:
            field: alternative
            kind: else_clause
            has: {{ kind: compound_statement, pattern: $IE }}
    transform:
      # The condition is rewritten too. discovery.cpp's only lambda sits
      # inside an `if` condition, and a raw capture left C++ in the output.
      IC_NL:
        rewrite: {{ rewriters: {expr_rw}, source: $ICR }}
      # Only an OPERATOR continuation is pulled up. A wrapped C++ condition
      # keeps its newlines, and Ruby ends the statement at the last complete
      # expression, so a line starting `&& ...` parses as a new statement and
      # fails. Flattening the condition WHOLESALE was wrong: a condition can
      # contain a `{{ |rec| ... }}` block whose newlines are its statement
      # separators, and collapsing those put the block body on the `if` line.
      # Transpile/MultilineCondition re-wraps the result afterwards.
      IC:
        replace: {{ source: $IC_NL, replace: '\\s*\\n\\s*(?<OP>&&|\\|\\|)', by: ' $OP' }}
      TBODY_RAW:
        rewrite: {{ rewriters: {nxt}, source: $IT }}
      TBODY:
        replace: {{ source: $TBODY_RAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
      EBODY_RAW:
        rewrite: {{ rewriters: {nxt}, source: $IE }}
      EBODY:
        replace: {{ source: $EBODY_RAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: |-
      if $IC
      $TBODY
      else
      $EBODY
      end
  - id: s-if{t}
    rule:
      kind: if_statement
      {inside}
      not: {{ has: {{ field: alternative, kind: else_clause }} }}
      all:
        - has: {{ field: condition, kind: condition_clause, has: {{ pattern: $IC2R }} }}
        - has: {{ field: consequence, kind: compound_statement, pattern: $IT2 }}
    transform:
      # The condition is rewritten too. discovery.cpp's only lambda sits
      # inside an `if` condition, and a raw capture left C++ in the output.
      IC2_NL:
        rewrite: {{ rewriters: {expr_rw}, source: $IC2R }}
      # Only an OPERATOR continuation is pulled up. A wrapped C++ condition
      # keeps its newlines, and Ruby ends the statement at the last complete
      # expression, so a line starting `&& ...` parses as a new statement and
      # fails. Flattening the condition WHOLESALE was wrong: a condition can
      # contain a `{{ |rec| ... }}` block whose newlines are its statement
      # separators, and collapsing those put the block body on the `if` line.
      # Transpile/MultilineCondition re-wraps the result afterwards.
      IC2:
        replace: {{ source: $IC2_NL, replace: '\\s*\\n\\s*(?<OP>&&|\\|\\|)', by: ' $OP' }}
      TBODY2_RAW:
        rewrite: {{ rewriters: {nxt}, source: $IT2 }}
      TBODY2:
        replace: {{ source: $TBODY2_RAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: |-
      if $IC2
      $TBODY2
      end
  - id: s-while{t}
    rule:
      kind: while_statement
      {inside}
      all:
        - has: {{ field: condition, kind: condition_clause, has: {{ pattern: $WCR }} }}
        - has: {{ field: body, kind: compound_statement, pattern: $WB }}
    transform:
      # The condition is rewritten too. discovery.cpp's only lambda sits
      # inside an `if` condition, and a raw capture left C++ in the output.
      WC_NL:
        rewrite: {{ rewriters: {expr_rw}, source: $WCR }}
      # Only an OPERATOR continuation is pulled up. A wrapped C++ condition
      # keeps its newlines, and Ruby ends the statement at the last complete
      # expression, so a line starting `&& ...` parses as a new statement and
      # fails. Flattening the condition WHOLESALE was wrong: a condition can
      # contain a `{{ |rec| ... }}` block whose newlines are its statement
      # separators, and collapsing those put the block body on the `if` line.
      # Transpile/MultilineCondition re-wraps the result afterwards.
      WC:
        replace: {{ source: $WC_NL, replace: '\\s*\\n\\s*(?<OP>&&|\\|\\|)', by: ' $OP' }}
      WBODY_RAW:
        rewrite: {{ rewriters: {nxt}, source: $WB }}
      WBODY:
        replace: {{ source: $WBODY_RAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: |-
      while $WC
      $WBODY
      end
  # A map loop: `for (const auto &f : entries)` whose body uses the pair
  # members. 00-alias.yml has already turned `f.first`/`f.second` into the
  # identifiers `f_first`/`f_second`, so the pair is visible here with no type
  # knowledge, and Ruby destructures it in the block parameters.
  #
  # The names come from what the C++ writes. Nothing in the source supplies
  # better ones -- no identifier, parameter or comment says what the key means.
  - id: s-foreach-pair{t}
    rule:
      kind: for_range_loop
      {inside}
      all:
        - has: {{ field: declarator, stopBy: end, kind: identifier, pattern: $PFV }}
        - has: {{ field: right, pattern: $PFC }}
        - has: {{ field: body, kind: compound_statement, pattern: $PFB }}
        - has:
            stopBy: end
            kind: identifier
            regex: '_(first|second)$'
    transform:
      PFBODY_RAW:
        rewrite: {{ rewriters: {nxt}, source: $PFB }}
      PFBODY:
        replace: {{ source: $PFBODY_RAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
      PFK:
        replace: {{ source: $PFV, replace: '^(.*)$', by: '${{1}}_first' }}
      PFVAL:
        replace: {{ source: $PFV, replace: '^(.*)$', by: '${{1}}_second' }}
    fix: |-
      $PFC.each do |$PFK, $PFVAL|
      $PFBODY
      end
  # `for (auto &e : coll)` -> `coll.each do |e|`
  - id: s-foreach{t}
    rule:
      kind: for_range_loop
      {inside}
      all:
        - has: {{ field: declarator, stopBy: end, kind: identifier, pattern: $FV }}
        - has: {{ field: right, pattern: $FC }}
        - has: {{ field: body, kind: compound_statement, pattern: $FB }}
    transform:
      FBODY_RAW:
        rewrite: {{ rewriters: {nxt}, source: $FB }}
      FBODY:
        replace: {{ source: $FBODY_RAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: |-
      $FC.each do |$FV|
      $FBODY
      end
  # A counted for has no Ruby equivalent that keeps the induction variable
  # visible, so it lowers to `loop do` with the init/step left in the body.
  - id: s-for{t}
    rule:
      kind: for_statement
      {inside}
      has: {{ field: body, kind: compound_statement, pattern: $FB2 }}
    transform:
      FBODY2_RAW:
        rewrite: {{ rewriters: {nxt}, source: $FB2 }}
      FBODY2:
        replace: {{ source: $FBODY2_RAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: |-
      loop do
      $FBODY2
      end
  - id: s-switch{t}
    rule:
      kind: switch_statement
      {inside}
      all:
        - has: {{ field: condition, kind: condition_clause, has: {{ pattern: $SWCR }} }}
        - has: {{ field: body, kind: compound_statement, pattern: $SWB }}
    transform:
      # The condition is rewritten too. discovery.cpp's only lambda sits
      # inside an `if` condition, and a raw capture left C++ in the output.
      SWC_NL:
        rewrite: {{ rewriters: {expr_rw}, source: $SWCR }}
      # Only an OPERATOR continuation is pulled up. A wrapped C++ condition
      # keeps its newlines, and Ruby ends the statement at the last complete
      # expression, so a line starting `&& ...` parses as a new statement and
      # fails. Flattening the condition WHOLESALE was wrong: a condition can
      # contain a `{{ |rec| ... }}` block whose newlines are its statement
      # separators, and collapsing those put the block body on the `if` line.
      # Transpile/MultilineCondition re-wraps the result afterwards.
      SWC:
        replace: {{ source: $SWC_NL, replace: '\\s*\\n\\s*(?<OP>&&|\\|\\|)', by: ' $OP' }}
      SWBODY_RAW:
        rewrite: {{ rewriters: {nxt}, source: $SWB }}
      SWBODY:
        replace: {{ source: $SWBODY_RAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: |-
      case $SWC
      $SWBODY
      end
  # A C++ fall-through label pair:
  #
  #     case CSYNC_NOT_EXCLUDED:
  #     case CSYNC_FILE_SILENTLY_EXCLUDED:
  #         Q_UNREACHABLE();
  #
  # In C++ the empty label shares the next label's body, so the faithful Ruby
  # is one `when` with both values. Splitting them -- giving the first an empty
  # body -- silently changes behaviour, because the first value then does
  # nothing instead of reaching the shared body.
  #
  # Two rules, because one fix replaces one node: s-case-pair rewrites the
  # label that HAS the body and pulls the preceding empty label's value in via
  # `follows`, and s-case-absorbed deletes that now-redundant empty label. Same
  # shape as the pair in rules/00-alias.yml.
  #
  # The empty body is `{{ }}`, courtesy of rules/simplify.yml's
  # s-brace-case-empty, and "empty" is tested as having no named child.
  - id: s-case-pair{t}
    rule:
      kind: case_statement
      inside: {{ kind: compound_statement }}
      all:
        - has: {{ field: value, pattern: $PCV }}
        - has: {{ kind: compound_statement, pattern: $PCB, has: {{ nthChild: 1 }} }}
        - follows:
            kind: case_statement
            all:
              - has: {{ field: value, pattern: $PCVPREV }}
              - has: {{ kind: compound_statement, not: {{ has: {{ nthChild: 1 }} }} }}
    transform:
      PCBODY_RAW:
        rewrite: {{ rewriters: {nxt}, source: $PCB }}
      PCBODY:
        replace: {{ source: $PCBODY_RAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: |-
      when $PCVPREV, $PCV
      $PCBODY
  # The empty label absorbed by s-case-pair above.
  - id: s-case-absorbed{t}
    rule:
      kind: case_statement
      inside: {{ kind: compound_statement }}
      all:
        - has: {{ field: value, pattern: $ACV }}
        - has: {{ kind: compound_statement, not: {{ has: {{ nthChild: 1 }} }} }}
        - precedes:
            kind: case_statement
            has: {{ kind: compound_statement, has: {{ nthChild: 1 }} }}
    fix: ""
  # `case X: {{ ... }}` -> `when X`, and `default: {{ ... }}` -> `else`.
  #
  # Rebuilt from the node's own fields, never from the label's text.
  # rules/simplify.yml has already braced every case body and dropped the
  # trailing `break`, so each case_statement here has exactly one
  # compound_statement child and the body rewrite is the same shape as every
  # other block.
  #
  # Doing it structurally is the point: stripping `case ...:` with a regex ate
  # the first statement whenever the label line also held a `:` from a ternary.
  - id: s-case{t}
    rule:
      kind: case_statement
      inside: {{ kind: compound_statement }}
      all:
        - has: {{ field: value, pattern: $CV }}
        - has: {{ kind: compound_statement, pattern: $CB }}
    transform:
      CBODY_RAW:
        rewrite: {{ rewriters: {nxt}, source: $CB }}
      CBODY:
        replace: {{ source: $CBODY_RAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: |-
      when $CV
      $CBODY
  # `default:` has no `value` field, which is the whole discriminator.
  - id: s-default{t}
    rule:
      kind: case_statement
      inside: {{ kind: compound_statement }}
      has: {{ kind: compound_statement, pattern: $DB }}
      not: {{ has: {{ field: value, pattern: $DV }} }}
    transform:
      DBODY_RAW:
        rewrite: {{ rewriters: {nxt}, source: $DB }}
      DBODY:
        replace: {{ source: $DBODY_RAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: |-
      else
      $DBODY
  - id: s-block{t}
    rule:
      kind: compound_statement
      {inside}
      pattern: $CB
    transform:
      CBODY_RAW:
        rewrite: {{ rewriters: {nxt}, source: $CB }}
      CBODY:
        replace: {{ source: $CBODY_RAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: "$CBODY"
"""
    # No catch-all: without joinBy, anything no rewriter matches is preserved
    # verbatim, so there is nothing to catch. A catch-all here would actively
    # harm, matching nodes that would otherwise pass through untouched.
    return out


DECL_REWRITERS = """  # ---- parameters --------------------------------------------------------
  # A parameter reduces to its NAME. The declarator is searched with
  # `stopBy: end` because the name can sit under a nested declarator, but the
  # search is scoped to the `declarator` field -- an unscoped search walks the
  # TYPE too and `QSharedPointer<Vfs> vfs` then yields the template argument
  # `Vfs` instead of `vfs`.
  - id: p-named
    rule:
      kind: parameter_declaration
      has: { field: declarator, stopBy: end, kind: identifier, pattern: $PN }
    fix: "$PN"
  # `void f(int)` -- a declared but unnamed parameter still occupies a slot.
  - id: p-unnamed
    rule:
      kind: parameter_declaration
      not: { has: { field: declarator, stopBy: end, kind: identifier, pattern: $PANY } }
    fix: "_"
  - id: p-variadic
    rule:
      kind: variadic_parameter_declaration
      has: { field: declarator, stopBy: end, kind: identifier, pattern: $PV }
    fix: "*$PV"
  # ---- log chain operands ------------------------------------------------
  # Used by s-log at every tier. Untiered because they do not recurse.
  #
  # g-head must come first in s-log's rewriter list: the `qCInfo(lcDisco)` call
  # is also an operand of the chain, and g-val would otherwise interpolate it.
  - id: g-head
    rule:
      kind: call_expression
      has:
        field: function
        stopBy: end
        kind: identifier
        regex: '^qC(Info|Debug|Warning|Critical|Fatal)$'
    fix: ""
  # A string literal operand contributes its text. `u"..."` is a UTF-16 literal
  # prefix, which Ruby has no equivalent of and does not need.
  - id: g-lit
    rule:
      kind: string_literal
      pattern: $GL
    transform:
      GLIT:
        replace: { source: $GL, replace: '^u?"|"$', by: '' }
    # Bracketed with a `@~@` sentinel, which s-log strips at the end.
    # A printable marker rather than a control character: YAML rejects a raw
    # control char in a scalar, and this is far easier to see in tmp/.
    #
    # Without a marker the literal's own edge spaces are indistinguishable from
    # layout once the quotes are gone: `u"Processing (db|local|remote) "` ends
    # with a space that belongs in the output, and the separator pattern
    # `\s*<<\s*` ate it -- while matching only `<<` instead kept the layout
    # space on BOTH sides and gave three. The marker bounds the content, so
    # `\s*` stops at it and exactly one separator space is inserted.
    fix: "@~@$GLIT@~@"
  # Any other operand is interpolated. `not: binary_expression` keeps this off
  # the chain's own inner nodes, so only the leaves match.
  # A parenthesised operand is unwrapped first: rules/simplify.yml puts parens
  # round every ternary, and inside `#{...}` they are redundant -- the golden
  # writes `#{a ? b : c}`. Listed before g-val so it claims the node.
  - id: g-val-paren
    rule:
      kind: parenthesized_expression
      inside: { kind: binary_expression }
      has: { pattern: $GVP }
    fix: "#{$GVP}"
  - id: g-val
    rule:
      pattern: $GV
      inside: { kind: binary_expression }
      not: { kind: binary_expression }
    fix: "#{$GV}"
  # ---- declarations ------------------------------------------------------
  # Comments. Must be a rewriter in THIS rule, not an earlier pass: `#` at the
  # start of a line is a preprocessor directive to a C++ parser, so converting
  # comments first fills the file with ERROR nodes and every structural rule
  # then matches nothing.
  - id: r-comment
    rule:
      kind: comment
      pattern: $C
      inside: { kind: translation_unit }
    transform:
      CB:
        replace: { source: $C, replace: '(?m)^[ \\t]*(?:/\\*+|//+|\\*+/|\\*)[ \\t]?', by: '# ' }
    fix: "$CB"
  # `#include "x.h"` -> `require_relative "x"`. The .h is dropped: Ruby's
  # require_relative names a Ruby file, and the golden has no extensions.
  - id: r-include-local
    rule:
      kind: preproc_include
      has: { field: path, kind: string_literal, pattern: $IP }
    transform:
      IPB:
        replace: { source: $IP, replace: '\.(h|hpp|hxx)"$', by: '"' }
    fix: |
      require_relative $IPB
  # `#include <QFile>` -> `require "qfile"`. Angle brackets name a library, and
  # Ruby library names are lowercase.
  - id: r-include-system
    rule:
      kind: preproc_include
      has: { field: path, kind: system_lib_string, pattern: $SP }
    transform:
      SPN:
        replace: { source: $SP, replace: '^<|>$', by: '' }
      SPL:
        convert: { source: $SPN, toCase: lowerCase }
    fix: |
      require "$SPL"
  # `void A::f(args) { ... }` -> `def f(args) ... end`, tagged with its scope so
  # rubyify.py can group all of a class's methods under ONE wrapper. Emitting
  # the wrapper here would produce one `class A ... end` per method -- 658 of
  # them across the tree in an earlier attempt.
  - id: r-method
    rule:
      kind: function_definition
      all:
        - has:
            field: declarator
            stopBy: end
            kind: function_declarator
            all:
              # qualified_identifier ONLY. A free function at namespace scope
              # -- `static bool computeLocalChecksum(...)` -- has a plain
              # identifier here, and MSCOPE's `::[^:]*$` strip then leaves the
              # function's own name, so it was tagged
              # `# @class computeLocalChecksum` and rubyify.py opened a class
              # named after it. r-function handles that case with no tag.
              - has:
                  field: declarator
                  stopBy: end
                  kind: qualified_identifier
                  pattern: $QN
              - has: { field: parameters, kind: parameter_list, pattern: $MP }
        - has: { field: body, kind: compound_statement, pattern: $MB }
    transform:
      # The struct declarations, lifted above the def.
      MSTRUCTS:
        rewrite:
          rewriters: [s-struct-1]
          source: $MB
          joinBy: "\\n"
      MRAW:
        rewrite: { rewriters: STMT1_NOSTRUCT, source: $MB }
      # Strip the body's own braces: without joinBy they are preserved like any
      # other unmatched text.
      MSTMTS:
        replace: { source: $MRAW, replace: '^\s*\{\s*|\s*\}\s*$', by: '' }
      # Parameter names only. joinBy IS used here, deliberately and unlike
      # everywhere else: the surrounding text to preserve would be the C++
      # types, which is exactly what must go.
      MARGS:
        rewrite:
          rewriters: [p-named, p-unnamed, p-variadic]
          source: $MP
          joinBy: ", "
      MNAME:
        replace: { source: $QN, replace: '^.*::', by: '' }
      MSCOPE:
        replace: { source: $QN, replace: '::[^:]*$', by: '' }
    fix: |-
      # @class $MSCOPE
      $MSTRUCTS
      def $MNAME($MARGS)
      $MSTMTS
      end
  # A free function at namespace scope -- `static bool f(args) { ... }` -- is
  # not a method, so it gets no `# @class` tag and rubyify.py leaves it at
  # module level, which is where the C++ put it.
  - id: r-function
    rule:
      kind: function_definition
      all:
        - has:
            field: declarator
            stopBy: end
            kind: function_declarator
            all:
              - has:
                  field: declarator
                  stopBy: end
                  any:
                    - kind: identifier
                    - kind: field_identifier
                  pattern: $FQN
              - has: { field: parameters, kind: parameter_list, pattern: $FMP }
        - has: { field: body, kind: compound_statement, pattern: $FMB }
        - not:
            has:
              field: declarator
              stopBy: end
              kind: qualified_identifier
        # The class this file's methods belong to.
        #
        # `static bool computeLocalChecksum(...)` is a file-private helper at
        # namespace scope, and the golden puts it inside the class with the
        # methods it helps -- which is where a private helper belongs in Ruby.
        # The scope is recovered by unification: the enclosing namespace also
        # holds `ProcessDirectoryJob::start` and friends, so $FSCOPE binds to
        # that qualified_identifier's scope and the emitted `# @class` tag makes
        # rubyify.py group the helper with them.
        #
        # One class per namespace is assumed, which holds for this tree; a
        # second class would see its helpers tagged with the first.
        - inside:
            kind: namespace_definition
            has:
              stopBy: end
              kind: qualified_identifier
              has: { field: scope, pattern: $FSCOPE }
    transform:
      FSTRUCTS:
        rewrite:
          rewriters: [s-struct-1]
          source: $FMB
          joinBy: "\n"
      FRAW:
        rewrite: { rewriters: STMT1_NOSTRUCT, source: $FMB }
      FSTMTS:
        replace: { source: $FRAW, replace: '^\s*\{\s*|\s*\}\s*$', by: '' }
      FMARGS:
        rewrite:
          rewriters: [p-named, p-unnamed, p-variadic]
          source: $FMP
          joinBy: ", "
      FNAME:
        convert: { source: $FQN, toCase: snakeCase }
    fix: |-
      # @class $FSCOPE
      $FSTRUCTS
      def $FNAME($FMARGS)
      $FSTMTS
      end
  # A struct of plain data members -> Struct.new(..., keyword_init: true), the
  # form the golden uses for `struct Entries`.
  - id: r-struct-field
    rule:
      kind: field_declaration
      inside: { kind: field_declaration_list }
      has:
        field: declarator
        stopBy: end
        kind: field_identifier
        pattern: $SF
      not:
        has: { field: declarator, stopBy: end, kind: function_declarator }
    fix: ":$SF"
  - id: r-struct
    rule:
      any:
        - kind: struct_specifier
        - kind: class_specifier
      all:
        - has: { field: name, kind: type_identifier, pattern: $SN }
        - has: { field: body, kind: field_declaration_list, pattern: $SB }
        - not:
            has:
              stopBy: end
              kind: function_declarator
    transform:
      SFIELDS:
        rewrite:
          rewriters: [r-struct-field]
          source: $SB
          joinBy: ", "
    fix: "$SN = Struct.new($SFIELDS, keyword_init: true)"
  # An enum becomes a module of symbols; the golden compares against
  # :normal_query, so the VALUES are symbols rather than integers.
  - id: r-enumerator
    rule:
      kind: enumerator
      has: { field: name, kind: identifier, pattern: $EV }
    fix: "$EV = :$EV"
  - id: r-enum
    rule:
      kind: enum_specifier
      all:
        - has: { field: name, kind: type_identifier, pattern: $EN }
        - has: { field: body, kind: enumerator_list, pattern: $EB }
    transform:
      EVALS:
        rewrite:
          rewriters: [r-enumerator]
          source: $EB
          joinBy: "\\n"
    fix: |-
      module $EN
      $EVALS
      end
  # `namespace OCC { ... }` -> `module OCC ... end`, recursing into everything
  # it contains.
  - id: r-namespace
    rule:
      kind: namespace_definition
      all:
        - has: { field: name, stopBy: end, kind: namespace_identifier, pattern: $NN }
        - has: { field: body, kind: declaration_list, pattern: $NB }
    transform:
      NRAW:
        rewrite:
          rewriters: [r-comment-inner, r-method, r-function, r-struct, r-enum]
          source: $NB
      NBODY:
        replace: { source: $NRAW, replace: '^\s*\{\s*|\s*\}\s*$', by: '' }
    fix: |-
      module $NN
      $NBODY
      end
  - id: r-comment-inner
    rule:
      kind: comment
      inside: { kind: declaration_list }
      pattern: $CI
    transform:
      CIB:
        replace: { source: $CI, replace: '(?m)^[ \\t]*(?:/\\*+|//+|\\*+/|\\*)[ \\t]?', by: '# ' }
    fix: "$CIB"
"""

HEADER = '''# C++ -> Ruby transformation, generated by golden-harness/build_transform.py.
# Do not edit by hand; edit the generator.
#
# ONE rule, rooted at translation_unit, because every ast-grep pass needs
# parseable C++ input and the first pass to emit Ruby destroys that for all the
# rest. A `# comment` and a `require_relative "x.h"` are both invalid C++ -- `#`
# at line start is a preprocessor directive -- so comment and include rewriting
# cannot precede the structural rules. They are rewriters here instead.
#
# Target: golden-harness/discovery.cpp.rb, compared by golden-harness/compare.py.
id: cpp-to-ruby
language: cpp
severity: hint
rule:
  kind: translation_unit
  pattern: $TU

rewriters:
'''

FOOTER = '''transform:
  OUT:
    rewrite:
      rewriters: [r-comment, r-include-local, r-include-system, r-namespace,
                  r-method, r-function, r-struct, r-enum]
      source: $TU

fix: "$OUT"
'''


def main() -> int:
    tiers = "".join(statement_tier(n) for n in range(1, DEPTH + 1))
    tier1 = stmt_ids(1, leaves_only=False)
    tier1_nostruct = tier1.replace("s-struct-1", "s-struct-drop-1")
    decls = (DECL_REWRITERS
             .replace("STMT1_NOSTRUCT", tier1_nostruct)
             .replace("STMT1", tier1))
    out = HEADER + tiers + decls + FOOTER
    target = HERE / "transform.yml"
    target.write_text(out)
    rewriters = out.count("\n  - id: ")
    print(f"wrote {target.relative_to(HERE.parent)} "
          f"({len(out.splitlines())} lines, {rewriters} rewriters, depth {DEPTH})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

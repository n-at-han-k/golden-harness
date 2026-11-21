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
DEPTH = 7

# Order matters: the idiom rules come FIRST so they win over the generic
# declaration and expression rules, which would otherwise match the same nodes.
STMT_LEAVES = ["s-struct", "s-map-decl", "s-assert", "s-decl", "s-decl-bare",
               "s-expr", "s-return", "s-return-void", "s-next", "s-break"]
# s-lambda-call is a BLOCK, not a leaf: it rewrites the lambda's body through
# {nxt}, so it can only exist while a next tier does. It must also come FIRST,
# ahead of s-expr -- a call with a trailing lambda is also an
# expression_statement, and the first matching rewriter in the list wins.
STMT_BLOCKS = ["s-if-else", "s-if", "s-while", "s-foreach",
               "s-for", "s-switch", "s-block"]


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
    expr_rw = (f"[l-iife-{tier}, l-call-brace-{tier}]"
               if not last else f"[l-iife-{tier}]")

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
              regex: '^(OC_ASSERT|OC_ASSERT_X|OC_ENFORCE|OC_ENFORCE_X)$'
          - has:
              field: arguments
              kind: argument_list
              has: {{ pattern: $ACOND }}
    fix: |-
      unless $ACOND
      raise
      end
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
      DV:
        rewrite: {{ rewriters: {expr_rw}, source: $DVR }}
    fix: "$DN = $DV"
  - id: s-decl-bare{t}
    rule:
      kind: declaration
      {inside}
      all:
        - has: {{ field: declarator, kind: identifier, pattern: $DNB }}
        - not: {{ has: {{ field: declarator, kind: init_declarator }} }}
    fix: "$DNB = nil"
  - id: s-expr{t}
    rule:
      kind: expression_statement
      {inside}
      has: {{ pattern: $EX }}
    fix: "$EX"
  - id: s-return{t}
    rule:
      kind: return_statement
      {inside}
      has: {{ stopBy: end, pattern: $RV }}
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
  - id: l-arg{t}
    rule:
      inside: {{ kind: argument_list }}
      pattern: $LA
      not: {{ kind: lambda_expression }}
    fix: "$LA"
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
          rewriters: [l-arg{t}]
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
          rewriters: [l-arg{t}]
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
      IC:
        rewrite: {{ rewriters: {expr_rw}, source: $ICR }}
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
      IC2:
        rewrite: {{ rewriters: {expr_rw}, source: $IC2R }}
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
      WC:
        rewrite: {{ rewriters: {expr_rw}, source: $WCR }}
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
      SWC:
        rewrite: {{ rewriters: {expr_rw}, source: $SWCR }}
      SWBODY_RAW:
        rewrite: {{ rewriters: {nxt}, source: $SWB }}
      SWBODY:
        replace: {{ source: $SWBODY_RAW, replace: '^\\s*\\{{\\s*|\\s*\\}}\\s*$', by: '' }}
    fix: |-
      case $SWC
      $SWBODY
      end
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
              - has:
                  field: declarator
                  stopBy: end
                  any:
                    - kind: qualified_identifier
                    - kind: identifier
                    - kind: field_identifier
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
          rewriters: [r-comment-inner, r-method, r-struct, r-enum]
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
                  r-method, r-struct, r-enum]
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

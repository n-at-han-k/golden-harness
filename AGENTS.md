# golden-harness

DO NOT FUCKING DO A SINGLE FUCKING THING UNTIL YOU'VE FUCKING STUDIED THESE RESOURCES:
* clone and read https://github.com/ast-grep/ast-grep.github.io
* read the agent skill from https://github.com/ast-grep/agent-skill

## Development

1. First you generate a golden from a new input file that the user has todl you to add...
2. Then the user will confirm that the golden is correct, or make changes to it to make it correct...
3. Then it is your task to run the pipeline to generate the output and compare against the golden.
4. Once the output matches teh golden 100% it's time for the next input...

## RULES

### Line spacing

* All line spacing is handled by rubocop...

### When to use which tool

* ast-grep is semantics/syntax
* rubocop is styling

For example: multi-line conditional parens are styling therefore rubocop.


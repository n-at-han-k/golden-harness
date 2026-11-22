# Claude hooks for OpenCode

A minimal OpenCode V2 plugin that runs command hooks from `.claude/settings.json`.
The directory is auto-discovered at `.opencode/plugins/claude-hooks`; no OpenCode
configuration is required. Run `npm install` here after copying it somewhere else.

Use the normal Claude Code schema in `.claude/settings.json`:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "./scripts/check-command.sh",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

Set the plugin's `config` option to use a different settings file. Relative paths
are resolved from the project directory.

## Supported subset

- Events: `PreToolUse`, `PostToolUse`, `PostToolUseFailure`,
  `UserPromptSubmit`, and `Stop`.
- Command hooks with `command`, optional exec-form `args`, `timeout`, and
  tool-name `matcher` patterns.
- JSON input on stdin and `CLAUDE_PROJECT_DIR` in the environment.
- Exit code 2, `decision: "block"`, `continue: false`, and PreToolUse `deny`
  decisions block execution. PreToolUse `updatedInput` is applied.
- A blocking `Stop` reason is sent back as a synthetic message using OpenCode's
  `experimental.idle` hook.

Other events and handler types are ignored. Handlers run sequentially; `async`,
HTTP/prompt/agent/MCP handlers, and other advanced output transformations are
not implemented.

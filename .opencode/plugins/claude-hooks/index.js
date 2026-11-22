import { spawn } from "node:child_process"
import { readFile } from "node:fs/promises"
import { resolve } from "node:path"
import { Plugin } from "@opencode/plugin"

const toolNames = {
  bash: "Bash",
  shell: "Bash",
  read: "Read",
  edit: "Edit",
  write: "Write",
  multiedit: "MultiEdit",
  glob: "Glob",
  grep: "Grep",
  webfetch: "WebFetch",
  websearch: "WebSearch",
}

function matches(matcher, tool) {
  if (!matcher || matcher === "*") return true
  if (!tool) return true

  const names = [tool, toolNames[tool.toLowerCase()]].filter(Boolean)
  if (/^[\w\- ,|]+$/.test(matcher)) {
    const choices = matcher.split(/[|,]/).map((choice) => choice.trim())
    return names.some((name) => choices.includes(name))
  }

  const pattern = new RegExp(matcher)
  return names.some((name) => pattern.test(name))
}

function execute(hook, input, cwd) {
  return new Promise((resolve, reject) => {
    const interpolate = (value) => value.replaceAll("${CLAUDE_PROJECT_DIR}", cwd)
    const args = hook.args?.map(interpolate)
    const child = spawn(interpolate(hook.command), args ?? [], {
      cwd,
      env: { ...process.env, CLAUDE_PROJECT_DIR: cwd },
      shell: args === undefined,
      timeout: (hook.timeout ?? 600) * 1000,
    })
    let stdout = ""
    let stderr = ""

    child.stdout.on("data", (chunk) => (stdout += chunk))
    child.stderr.on("data", (chunk) => (stderr += chunk))
    child.stdin.on("error", () => {})
    child.on("error", reject)
    child.on("close", (code) => resolve({ code: code ?? 1, stdout, stderr }))
    child.stdin.end(JSON.stringify(input))
  })
}

async function runHooks(event, input, groups, cwd) {
  for (const group of groups) {
    if (!matches(group.matcher, input.tool_name)) continue

    for (const hook of group.hooks ?? []) {
      if (hook.type !== "command") continue

      const result = await execute(hook, input, cwd)
      let output = {}
      if (result.code === 0 && result.stdout.trim()) {
        try {
          output = JSON.parse(result.stdout) ?? {}
        } catch {}
      }

      const specific = output.hookSpecificOutput ?? {}
      const blocked =
        result.code === 2 ||
        output.continue === false ||
        output.decision === "block" ||
        specific.permissionDecision === "deny"

      if (blocked) {
        return (
          result.stderr.trim() ||
          output.reason ||
          output.stopReason ||
          specific.permissionDecisionReason ||
          `Claude ${event} hook blocked execution`
        )
      }

      if (result.code !== 0) {
        console.error(`[claude-hooks] ${event} hook exited ${result.code}: ${result.stderr.trim()}`)
        continue
      }

      if (event === "PreToolUse" && specific.updatedInput !== undefined) {
        input.tool_input = specific.updatedInput
      }
    }
  }

  return null
}

export default Plugin.define({
  id: "claude-hooks",
  async setup(ctx) {
    const cwd = ctx.location.directory
    const config = resolve(cwd, ctx.options.config ?? ".claude/settings.json")
    let settings

    try {
      settings = JSON.parse(await readFile(config, "utf8"))
    } catch (error) {
      if (error.code === "ENOENT") return
      throw error
    }

    if (settings.disableAllHooks) return
    const hooks = settings.hooks ?? {}
    const registrations = []

    if (hooks.PreToolUse?.length) {
      registrations.push(
        await ctx.tool.hook("execute.before", async (event) => {
          const input = {
            session_id: event.sessionID,
            cwd,
            hook_event_name: "PreToolUse",
            tool_name: event.tool,
            tool_input: event.input,
          }
          const reason = await runHooks("PreToolUse", input, hooks.PreToolUse, cwd)
          if (reason) throw new Error(reason)
          event.input = input.tool_input
        }),
      )
    }

    if (hooks.PostToolUse?.length || hooks.PostToolUseFailure?.length) {
      registrations.push(
        await ctx.tool.hook("execute.after", async (event) => {
          const name = event.status === "completed" ? "PostToolUse" : "PostToolUseFailure"
          if (!hooks[name]?.length) return

          const input = {
            session_id: event.sessionID,
            cwd,
            hook_event_name: name,
            tool_name: event.tool,
            tool_input: event.input,
            tool_response: event.status === "completed" ? event.result : undefined,
            error: event.status === "error" ? event.error : undefined,
          }
          const reason = await runHooks(name, input, hooks[name], cwd)
          if (reason) throw new Error(reason)
        }),
      )
    }

    if (hooks.UserPromptSubmit?.length) {
      registrations.push(
        await ctx.session.hook("prompt", async (event) => {
          const input = {
            session_id: event.sessionID,
            cwd,
            hook_event_name: "UserPromptSubmit",
            prompt: event.prompt.text,
          }
          const reason = await runHooks("UserPromptSubmit", input, hooks.UserPromptSubmit, cwd)
          if (reason) throw new Error(reason)
        }),
      )
    }

    if (hooks.Stop?.length) {
      const continued = new Set()
      registrations.push(
        await ctx.session.hook("experimental.idle", async (event) => {
          const input = {
            session_id: event.sessionID,
            cwd,
            hook_event_name: "Stop",
            stop_hook_active: continued.has(event.sessionID),
          }
          const reason = await runHooks("Stop", input, hooks.Stop, cwd)
          if (!reason) {
            continued.delete(event.sessionID)
            return
          }

          continued.add(event.sessionID)
          await ctx.session.synthetic({ sessionID: event.sessionID, text: reason })
        }),
      )
    }

    return async () => {
      await Promise.all(registrations.map((registration) => registration.dispose()))
    }
  },
})

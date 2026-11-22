import assert from "node:assert/strict"
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"
import test from "node:test"
import plugin from "./index.js"

const script = `
  let data = ""
  process.stdin.on("data", (chunk) => data += chunk)
  process.stdin.on("end", () => {
    const input = JSON.parse(data)
    require("node:fs").writeFileSync(process.argv[1], JSON.stringify(input))
    if (input.hook_event_name === "PreToolUse") {
      process.stderr.write("blocked by test")
      process.exit(2)
    }
    if (input.hook_event_name === "Stop") {
      process.stderr.write("continue working")
      process.exit(2)
    }
  })
`

test("adapts Claude command hooks to OpenCode", async (t) => {
  const directory = await mkdtemp(join("/tmp/opencode/", "claude-hooks-"))
  t.after(() => rm(directory, { recursive: true, force: true }))

  const output = join(directory, "input.json")
  const command = {
    type: "command",
    command: process.execPath,
    args: ["-e", script, output],
    timeout: 5,
  }
  const group = { hooks: [command] }
  const settings = {
    hooks: {
      PreToolUse: [{ ...group, matcher: "Bash" }],
      PostToolUse: [group],
      UserPromptSubmit: [group],
      Stop: [group],
    },
  }
  await writeFile(join(directory, "settings.json"), JSON.stringify(settings))

  const callbacks = {}
  const synthetic = []
  const registration = () => ({ dispose: async () => {} })
  const cleanup = await plugin.setup({
    location: { directory },
    options: { config: "settings.json" },
    tool: {
      hook: async (name, callback) => {
        callbacks[name] = callback
        return registration()
      },
    },
    session: {
      hook: async (name, callback) => {
        callbacks[name] = callback
        return registration()
      },
      synthetic: async (input) => synthetic.push(input),
    },
  })
  t.after(cleanup)

  const before = { sessionID: "session-1", tool: "read", input: {} }
  await callbacks["execute.before"](before)
  await assert.rejects(
    callbacks["execute.before"]({ ...before, tool: "shell", input: { command: "ls" } }),
    /blocked by test/,
  )
  let input = JSON.parse(await readFile(output, "utf8"))
  assert.equal(input.hook_event_name, "PreToolUse")
  assert.equal(input.tool_name, "shell")
  assert.deepEqual(input.tool_input, { command: "ls" })

  await callbacks["execute.after"]({
    sessionID: "session-1",
    tool: "write",
    input: { filePath: "example.txt" },
    status: "completed",
    result: { content: "done" },
  })
  input = JSON.parse(await readFile(output, "utf8"))
  assert.equal(input.hook_event_name, "PostToolUse")
  assert.deepEqual(input.tool_response, { content: "done" })

  await callbacks.prompt({ sessionID: "session-1", prompt: { text: "hello" } })
  input = JSON.parse(await readFile(output, "utf8"))
  assert.equal(input.hook_event_name, "UserPromptSubmit")
  assert.equal(input.prompt, "hello")

  await callbacks["experimental.idle"]({ sessionID: "session-1" })
  input = JSON.parse(await readFile(output, "utf8"))
  assert.equal(input.stop_hook_active, false)
  await callbacks["experimental.idle"]({ sessionID: "session-1" })
  input = JSON.parse(await readFile(output, "utf8"))
  assert.equal(input.stop_hook_active, true)
  assert.deepEqual(synthetic, [
    { sessionID: "session-1", text: "continue working" },
    { sessionID: "session-1", text: "continue working" },
  ])
})

// Guard plugin for opencode-local-subagent. The wrapper loads it through the config it injects; it
// lives in the skill's directory, which the agent can't write (the sandbox denies writes there).
// One default export serves both plugin APIs: 1.x calls server(), 2.x reads id + setup().
// (1.x calls every named export as a plugin, so nothing else may be exported from this file.)
import { check } from "./rules.js"

const reject = (why) => new Error("blocked by the opencode-local-subagent guard: " + why)

export default {
  id: "ocls.guard",
  // OpenCode 2.x
  async setup(ctx) {
    await ctx.tool.hook("execute.before", (event) => {
      if (event.tool !== "shell" && event.tool !== "bash") return
      const why = check(event.input && event.input.command)
      if (why) throw reject(why)
    })
  },
  // OpenCode 1.x
  async server() {
    return {
      "tool.execute.before": async (input, output) => {
        if (input.tool !== "bash") return
        const why = check(output.args && output.args.command)
        if (why) throw reject(why)
      },
    }
  },
}

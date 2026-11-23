// Command rules of the guard plugin. Pure functions, so tests can run them with plain node.
// OpenCode matches its shell allow/deny patterns against the raw command text, so quoting or escaping
// ("-exec", -d\elete, git log "--output=f") slips past any deny pattern. The allowlist is therefore
// narrow, and this guard rejects every command that is not plain words, before the patterns apply.

// Plain words only: no quotes, backslashes, $, backticks, ;&|<>(), braces, globs, tabs, newlines, non-ASCII.
// ~ and ^ are also let through (HEAD~1, HEAD^), but not where the shell would expand a ~ to a home directory.
const PLAIN = /^[A-Za-z0-9 ./_=:@%+,~^-]+$/
const TILDE = /(^|[ =:])~/

// git options that run programs, redirect git's idea of repo/config, or write files. Matched as
// abbreviations too: git accepts any unambiguous prefix (--am for --amend), so a prefix is rejected.
const GIT_LONG = ["--git-dir", "--work-tree", "--exec-path", "--output", "--ext-diff", "--textconv", "--config-env", "--amend"]

export function check(command) {
  if (typeof command !== "string" || command.trim() === "") return "empty command"
  if (!PLAIN.test(command)) {
    return "only plain words are allowed in a command (letters, digits, space and ./_=:@%+,~^-); no quotes, escapes, $, `, ; & | < > ( ), tabs or newlines"
  }
  if (TILDE.test(command)) return "a ~ that the shell would expand is not allowed"
  const words = command.split(" ").filter(Boolean)
  const prog = words[0].split("/").pop()
  if (prog !== "git") return null
  for (const w of words.slice(1)) {
    if (/^-[cC]/.test(w)) return "git: -c / -C are not allowed"
    if (w.startsWith("--") && w !== "--") {
      const name = w.split("=")[0]
      if (GIT_LONG.some((o) => o.startsWith(name))) return "git: option " + name + " is not allowed"
    }
  }
  return null
}

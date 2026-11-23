// Table test for the guard plugin's command rules (plugin/guard/rules.js). Run with plain node.
import { check } from "../skills/opencode-local-subagent/plugin/guard/rules.js"

const allowed = [
  "git status", "git status -s", "git diff", "git diff HEAD~1 -- src/a.ts", "git log --oneline -5", "git log -p src/a.ts",
  "git show HEAD", "git show HEAD:src/a.ts", "git diff --no-ext-diff --no-textconv", "git add -A", "git add src/a.ts",
  "git commit --no-verify -m fix", "git commit -m wip", "/usr/bin/git log", "mkdir -p src/new/dir", "touch src/a.ts",
  "pytest tests/test_a.py -k name", "npm run test", "git log --format=%h", "git log --since=2.weeks --author=a@b.c",
  "git diff --word-diff", "git log --cached", "git log HEAD^..HEAD", "git diff HEAD~2 HEAD~1", "git show HEAD~1:src/a.ts",
]
const rejected = [
  // not plain words
  'find . "-exec" touch x {} +', "find . '-exec' touch x {} +", 'find . -d\\elete', "rg --p're=sh' x", 'git log "--output=f"',
  "git log '--output=f'", "echo $(id)", "echo `id`", "echo ${HOME}", "ls; id", "ls && id", "ls || id", "ls | sh", "ls > f",
  "ls >> f", "cat < f", "(ls)", "ls\tfoo", "ls\nid", "ls\rid", "echo é", "echo ‮", "ls *.txt", "ls ~", "ls a?", "ls {a,b}",
  "ls ~", "cat ~root/x", "ls a ~b", "ls --opt=~/x", "ls a:~/x", "echo a#b", "echo !x", "", "   ", "echo a\0b", "ls -la",
  // git options that run programs, redirect config/repo, or write files
  "git -c core.pager=x log", "git -c core.fsmonitor=x status", "git -cfoo=bar log", "git -C /tmp log", "git -C. log", "git log -C",
  "git --git-dir=/x log", "git --git-dir /x log", "git --git log", "git --work-tree=/x status", "git --work status", "git --exec-path=/x log",
  "git --exec-path", "git --config-env=core.pager=X log", "git --config-e=core.pager=X log", "git log --output=f", "git log --output f",
  "git diff --output=f", "git diff --out=f", "git diff --o=f", "git show --output=f", "git diff --ext-diff", "git diff --ext", "git log --ext-diff -p",
  "git diff --textconv", "git log --text -p", "git show --textconv HEAD:f", "git commit --amend", "git commit --amen", "git commit --ame",
  "git commit --am", "git commit --a", "git commit --amend --no-edit", "/usr/bin/git -c x=y log", "git log --git-dir=x",
]
let fail = 0
for (const c of allowed) { const w = check(c); if (w) { fail++; console.log("FAIL should be allowed: " + JSON.stringify(c) + " -> " + w) } }
for (const c of rejected) { const w = check(c); if (!w) { fail++; console.log("FAIL should be rejected: " + JSON.stringify(c)) } }
for (const bad of [null, undefined, 5, {}, []]) { if (!check(bad)) { fail++; console.log("FAIL non-string accepted: " + JSON.stringify(bad)) } }
console.log(fail === 0 ? "guard rules ok (" + (allowed.length + rejected.length) + " cases)" : "guard rules FAILED: " + fail)
process.exit(fail === 0 ? 0 : 1)

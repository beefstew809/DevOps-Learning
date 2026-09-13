# Git Workflows

Beyond `add`/`commit`/`push`: the model that makes the rest make sense, the commands worth knowing,
and the recovery paths.

## The model

Four places content lives:

```
working tree  ──add──►  index (staging)  ──commit──►  local repo  ──push──►  remote
```

A **commit** is a snapshot plus a parent pointer. A **branch** is a movable pointer to a commit.
`HEAD` points at the current branch. That is nearly the whole data model, and most confusing git
behaviour becomes obvious once you hold it: branches are cheap because they are one file containing
one hash.

```bash
git log --oneline --graph --all --decorate
git log --oneline main..feature      # in feature, not in main
git log --oneline feature..main      # the reverse — order matters
```

## Commits worth reading later

```
Short imperative summary under ~72 chars

Why this change exists. What the previous behaviour was and why it was
wrong. Not what the diff already shows.

Constraints or consequences a future reader needs: the flag that must be
set, the migration that must run first, the thing this deliberately does
not fix.
```

The test: six months later, `git log` should answer *why*. The diff already answers *what*.

Conventional Commits (`feat:`, `fix:`, `chore:`) are worth adopting if you want automated changelogs
or semantic versioning, and pointless otherwise — pick deliberately rather than by habit.

**Small commits that each build.** A commit that does two things cannot be reverted or
cherry-picked independently, and `git bisect` cannot isolate which half broke.

## Branching strategies

| Strategy | Shape | Fits |
| --- | --- | --- |
| **Trunk-based** | Short branches off `main`, merged in hours or days | CI/CD, feature flags, most teams |
| **GitHub Flow** | Branch, PR, review, merge, deploy `main` | Small teams, continuous deploy |
| **GitFlow** | `develop`, `release/*`, `hotfix/*`, `main` | Versioned releases, scheduled shipping |
| **Release branches** | `main` + long-lived `release-1.x` | Software others install |

Default to **trunk-based** unless you have a specific reason. The cost of long-lived branches is
superlinear: divergence grows, conflicts grow, and the merge becomes an event. A branch alive for
three weeks is a risk, not a workspace.

**Avoid branch-per-environment for deployments** — promotion becomes a merge, merges drift, and a
prod hotfix has to be back-merged. Directories express environments better; see
[../GitOps/gitops-principles.md](../GitOps/gitops-principles.md).

## Merge, rebase, squash

```bash
git merge feature                  # merge commit; preserves real history
git rebase main                    # replay your commits on top of main
git merge --squash feature         # one commit, discards the branch's history
```

| | Keeps history | Linear | Safe on shared branches |
| --- | --- | --- | --- |
| merge | yes | no | yes |
| rebase | rewritten | yes | **no** |
| squash | no | yes | yes |

**The rule: never rebase a branch other people have.** Rebasing rewrites commit hashes, so everyone
else's history diverges from yours and their next pull creates duplicates or conflicts. Rebase your
own unpushed work freely; use merge once it is shared.

A workable convention: rebase your feature branch onto `main` while you work (keeps it current,
keeps the eventual diff small), then merge or squash into `main`.

```bash
git pull --rebase                  # avoid merge commits from pulling
git config --global pull.rebase true
git rebase -i HEAD~5               # reorder, squash, reword — NOT available in this harness
```

Interactive rebase is the tool for cleaning up a messy local branch before review. Note it needs an
interactive terminal, so it is not usable from automation.

## Undoing things

The distinction that matters: **have you pushed?**

```bash
# not pushed — rewrite freely
git commit --amend                      # fix the last commit (message or content)
git reset --soft HEAD~1                 # undo commit, keep changes staged
git reset HEAD~1                        # undo commit, keep changes unstaged
git reset --hard HEAD~1                 # undo commit AND DISCARD changes
git restore file.txt                    # discard working-tree changes to a file
git restore --staged file.txt           # unstage, keep changes

# already pushed — add a new commit instead
git revert <sha>                        # the safe, shared-history answer
git revert -m 1 <merge-sha>             # revert a merge, keeping the first parent
```

`--hard` and `restore` destroy uncommitted work with no recovery. That is the one genuinely
dangerous pair.

```bash
git stash push -m "wip"
git stash list
git stash pop
git stash show -p stash@{0}
```

### The reflog saves you

Almost nothing is truly lost for ~90 days:

```bash
git reflog
git reset --hard HEAD@{2}           # back to where you were two moves ago
git checkout -b recovered <sha>     # resurrect a deleted branch
```

A "lost" commit after a bad reset or rebase is in the reflog. `git reflog` before panicking is the
habit worth building. The exception is **uncommitted** changes — those were never in git and the
reflog cannot help.

## Investigating

```bash
git bisect start
git bisect bad                      # current is broken
git bisect good v1.2.0              # this was fine
# git checks out midpoints; mark each
git bisect good|bad
git bisect reset

# automated, if you have a test
git bisect run ./test.sh
```

`git bisect run` with a script is the single most powerful debugging tool in git — it finds the
introducing commit in log₂(n) steps with no human in the loop. It is why small commits that each
build matter.

```bash
git blame -L 20,40 file.py
git log -p --follow file.py          # history across renames
git log -S 'functionName'            # commits that ADDED or REMOVED that string
git log -G 'regex'                   # commits whose diff matches
git diff main...feature              # three dots: changes on feature since it diverged
```

`git log -S` ("pickaxe") answers "when did this string appear or vanish", which `blame` cannot —
blame shows the last change to a line, not when the logic arrived.

## Worktrees

```bash
git worktree add ../project-hotfix main
git worktree list
git worktree remove ../project-hotfix
```

Multiple checkouts sharing one `.git`. Better than stashing when you need to work on two things, and
the right isolation for risky or automated changes — a separate directory means a bad change cannot
disturb your main checkout.

## Hooks

Local, in `.git/hooks`, and **not version-controlled** — so they are per-developer unless managed:

```bash
# .git/hooks/pre-commit
#!/usr/bin/env bash
set -e
gitleaks protect --staged --no-banner
shellcheck $(git diff --cached --name-only --diff-filter=ACM | grep '\.sh$') || true
```

Use `pre-commit` (the framework) to share them:

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.2
    hooks: [{id: gitleaks}]
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.35.1
    hooks: [{id: yamllint}]
```

```bash
pre-commit install
pre-commit run --all-files
```

**A secret scanner in `pre-commit` is the highest-value hook**, because it catches the leak at the
only point where cleanup is cheap. Hooks are bypassable with `--no-verify`, so CI must enforce the
same checks — hooks are a convenience, not a control.

## Large files

Git stores every version of every file forever. A committed 500 MB binary is permanent in clone
size.

```bash
git lfs install
git lfs track "*.psd"
```

Better: do not commit build artifacts, archives, images or binaries at all. Use a registry or object
storage and reference a version.

```bash
# what is making this repo large
git rev-list --objects --all | \
  git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' | \
  awk '$1=="blob"' | sort -k3 -n -r | head -20
```

## Removing something committed by mistake

For a **secret**: revoke it first. Rewriting history does not un-leak anything that was pushed — see
[../Secrets Management/secrets-management-patterns.md](../Secrets%20Management/secrets-management-patterns.md).

```bash
git filter-repo --path secrets.env --invert-paths
git filter-repo --path bigfile.zip --invert-paths
```

`git filter-repo` replaces the old `filter-branch` (and BFG). It rewrites every affected commit, so
**every clone must be re-cloned** and every open PR breaks. Coordinate it.

## Useful configuration

```bash
git config --global user.name "Name"
git config --global user.email "you@example.com"
git config --global init.defaultBranch main
git config --global pull.rebase true
git config --global rebase.autoStash true
git config --global diff.colorMoved zebra
git config --global rerere.enabled true
git config --global fetch.prune true
git config --global push.autoSetupRemote true
```

Two worth explaining:

- **`rerere.enabled`** — "reuse recorded resolution". Git remembers how you resolved a conflict and
  replays it automatically next time. Invaluable on a long-lived branch rebased repeatedly.
- **`fetch.prune`** — deletes local refs for branches removed on the remote, so `git branch -r`
  reflects reality.

Per-directory identity, for separating work and personal commits:

```
# ~/.gitconfig
[includeIf "gitdir:~/work/"]
  path = ~/.gitconfig-work
```

Sign commits if the forge verifies them — SSH signing is simpler than GPG:

```bash
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
git config --global commit.gpgsign true
```

## Multiple remotes

```bash
git remote -v
git remote add upstream git@example.com:other/repo.git
git remote set-url origin git@newhost:org/repo.git
git push origin main
```

**Verify the remote before trusting a note or a memory of where a repo lives.** A repo that moved
hosts leaves stale URLs in documentation, and pushing to the old one succeeds while changing
nothing that matters.

```bash
git remote get-url origin         # the authoritative answer
```

## Recovery cheat sheet

| Situation | Fix |
| --- | --- |
| Wrong commit message, not pushed | `git commit --amend` |
| Wrong message, pushed | Leave it, or force-push if you are the only user |
| Committed to the wrong branch | `git reset --soft HEAD~1`, switch, recommit |
| Need to undo a pushed commit | `git revert <sha>` |
| Bad rebase | `git reflog`, `git reset --hard HEAD@{n}` |
| Deleted a branch | `git reflog`, `git checkout -b name <sha>` |
| Discarded uncommitted work | Gone. The reflog cannot help |
| Committed a secret | **Revoke first**, then `git filter-repo` |
| Detached HEAD with commits | `git checkout -b newbranch` before switching away |
| Merge went wrong, not pushed | `git merge --abort` or `git reset --hard ORIG_HEAD` |

## Related

- [../GitOps/gitops-principles.md](../GitOps/gitops-principles.md) — git as deployment source of truth
- [../CI-CD/forgejo/forgejo-actions.md](../CI-CD/forgejo/forgejo-actions.md)
- [../Secrets Management/secrets-management-patterns.md](../Secrets%20Management/secrets-management-patterns.md) — scanning, and leaked-secret response

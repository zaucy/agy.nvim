# Antigravity Workspace Guidelines (agy.nvim)

## Core Philosophy: Assert, Don't Fall Back

1. **No Fallback Cascades (Fail Fast with Assertions)**:
   - Do not construct defensive fallback chains or silent default cascades (e.g. avoid `val or fallback_a or fallback_b or fallback_c`).
   - If a configuration entry, state variable, or function argument is expected, assert its presence explicitly with a clear, actionable error message.
   - Fail fast at the point of failure rather than letting missing or invalid state propagate.

2. **Do Not Over-Engineer for Hypothetical Edge Cases**:
   - Keep control flow simple, direct, and explicit.
   - Do not attempt to preemptively handle every conceivable edge case with defensive branching, guessing heuristics, or redundant safety nets.
   - Address concrete, verified requirements rather than speculative scenarios.

3. **No Aliasing or Synonym Layers**:
   - Always use canonical keys and names directly (e.g. direct table indexing `tbl[key]`).
   - Never introduce implicit alias maps, synonym fallback tables, or fuzzy key resolution layers (e.g. do not map `sign` to `prompt_sign` or `success` to `done`).

4. **Configuration-Driven Literals (No Hardcoded UI/Icon Text)**:
   - In UI and rendering modules (such as `lua/agy/render.lua`), never embed hardcoded visual literals, symbols, or fallback icon text (e.g. `"🛠️"`, `""`, `"✓"`, `"💭"`, `"❌"`).
   - Retrieve all visual markers from `config.icons`, asserting their existence.
   - Formally register customizable entries in `AgyConfigIcons` in `lua/agy/config.lua` and document them in `doc/agy.txt`.
   - Inspect buffer lines dynamically against active `config.icons` entries rather than hardcoded pattern sets.

## Verification & Testing

1. **Verification Command**:
   - The verification step for all changes is running the automated test suite with:
     ```sh
     test.nu -t
     ```
     (or `nu test.nu -t`). Always ensure this command passes before completing any task.

2. **Adding New Tests**:
   - Place new automated tests in the `tests/` directory as standalone Lua test scripts (e.g. `tests/test_<feature>.lua`).
   - Register any new test file in the `let tests = [...]` array inside `test.nu` so that it is included in automated test runs.
   - Tests execute in an isolated, clean Neovim instance (`nvim --clean -u NONE`) using the Lua script runner (`-l`). Shared utilities and mock helpers can be imported from `tests/test_helpers.lua`.

## Git & Worktree Workflow

1. **Worktree-First Changes**:
   - For all updates, feature work, refactors, and bug fixes, do not modify the primary working tree directly.
   - Create and work inside a dedicated Git worktree under `.worktrees/<branch-name>`:
     ```sh
     git worktree add .worktrees/<branch-name> -b <branch-name>
     ```
   - Perform all edits, staging, and verification within that worktree.

2. **Subagent Delegation**:
   - When invoking subagents via `invoke_subagent` that edit files or execute tests, set `Workspace: 'share'` (or `'branch'`) rather than `'inherit'` to ensure subagents work in isolated branch workspaces without colliding with the active working tree.

3. **Verification in the Worktree**:
   - Run the automated test suite within the worktree before completing any work:
     ```sh
     test.nu -t
     ```
     (or `nu test.nu -t`).

4. **Pull Requests & Worktree Preservation**:
   - Once changes are verified and committed, push the branch to the remote repository and create a Pull Request using `gh pr create`:
     ```sh
     git push -u origin <branch-name>
     gh pr create --fill
     ```
   - Do not delete or remove the worktree upon completion (never run `git worktree remove`). Leave the worktree intact under `.worktrees/<branch-name>` for review, manual verification, and future iterations.

#!/usr/bin/env nu

# Launch an isolated Neovim instance with agy.nvim loaded in a clean environment
def main [
    target: string = "new", # Target to open ("new", a conversation ID, or "resume")
    --test (-t),            # Run automated test suite instead of interactive editor
] {
    let repo_dir = ($env.FILE_PWD? | default ($env.PWD))
    let lua_repo_dir = ($repo_dir | str replace --all '\' '/')

    if $test {
        print "Running agy.nvim automated test suite in clean Neovim environment..."
        
        let tests = [
            "tests/test_shorten_path.lua",
            "tests/test_transcript.lua",
            "tests/test_protocol_buffer.lua",
            "tests/test_selection_and_reload.lua",
            "tests/test_prompt_submission.lua",
            "tests/test_reload_footer.lua",
            "tests/test_tool_toggle_and_path.lua",
            "tests/test_real_conversation_tool_calls.lua",
            "tests/test_issues_fixes.lua",
            "tests/test_ask_question.lua",
            "tests/test_modern_rendering.lua",
            "tests/test_workspaces.lua",
            "tests/test_native_autocomplete.lua",
            "tests/test_quota.lua",
            "tests/test_e2e_turn.lua",
            "tests/test_resume_conversation.lua",
            "tests/test_compact_tools_transcript.lua",
            "tests/test_tasks.lua",
            "tests/test_config_icons.lua",
            "tests/test_separators.lua",
            "tests/test_live_vs_reload_identical.lua",
            "tests/test_inline_tool_window.lua",
            "tests/test_prompt_queue.lua",
            "tests/test_prompt_border_active_turn.lua",
            "tests/test_cursor_prompt_anchoring.lua",
            "tests/test_scroll_bottom_virtual_text.lua",
            "tests/test_stream_markdown.lua",
            "tests/test_background_task_freeze.lua",
            "tests/test_header_logo.lua",
            "tests/test_artifacts.lua",
            "tests/test_home.lua",
            "tests/test_async.lua",
            "tests/test_stream_throttle.lua",
            "tests/test_thoughts_lifecycle.lua",
            "tests/test_history_logging.lua",
            "tests/test_thinking_prompt_relocation.lua",
            "tests/test_db.lua"
        ]

        for t in $tests {
            print $"\n==> Running ($t)..."
            nvim --clean -u NONE --cmd $"set rtp+=($lua_repo_dir)" -l $t
        }
        print "\n✓ All tests finished!"
        return
    }

    # Generate temporary mini init.lua
    let mini_init = [
        $"vim.opt.runtimepath:append\(vim.fs.normalize\('($lua_repo_dir)'\)\)"
        "vim.cmd('filetype plugin indent on')"
        "vim.cmd('syntax on')"
        "local agy = require('agy')"
        "agy.setup({"
        "  ui = {"
        "    virtual_text = true,"
        "    auto_scroll = true,"
        "    fold_tool_output = true,"
        "  },"
        "})"
        "vim.opt.number = false"
        "vim.opt.wrap = true"
        "vim.opt.cursorline = true"
    ] | str join "\n"

    let tmp_dir = ($nu.temp-path? | default ($env.TEMP? | default ($env.TMPDIR? | default "/tmp")))
    let tmp_init = ($tmp_dir | path join "agy_mini_init.lua")
    $mini_init | save --force $tmp_init

    let buffer_target = if $target == "new" {
        "agy://new"
    } else if ($target | str starts-with "agy://") {
        $target
    } else if $target == "resume" {
        ""
    } else {
        $"agy://($target)"
    }

    print $"Starting clean Neovim with agy.nvim loaded..."
    print $"  Repository: ($lua_repo_dir)"
    print $"  Target:     ($target)"
    print "Tip: Inside the buffer, type your prompt under '### 👤 User' and press :w or <C-s> to submit."
    print "     Press <C-c> to stop a running turn.\n"

    if $target == "resume" {
        nvim --clean -u $tmp_init -c "AgyResume"
    } else {
        nvim --clean -u $tmp_init $buffer_target
    }
}

# agy.nvim

Antigravity neovim buffer! Just open a new buffer with `:e agy://new` to get started.

NOTE: experimental WIP

## Quick test / try

A `test.nu` script is included to quickly launch clean, isolated Neovim instances:

```sh
# Open a clean session with agy://new
nu test.nu

# Open a clean session resuming a specific conversation
nu test.nu <conversation-id>

# Open clean session with the conversation picker
nu test.nu resume

# Run automated headless test suite
nu test.nu --test
```

## License

MIT

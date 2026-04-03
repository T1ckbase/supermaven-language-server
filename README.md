# supermaven-language-server

> [!WARNING]
> This project is vibe-coded — proceed with caution.

Pure Lua, in-process Supermaven language server for Neovim 0.12.

This project wraps the existing `sm-agent` binary behind Neovim's built-in LSP client and exposes `textDocument/inlineCompletion` instead of managing its own preview UI, keymaps, or completion source.

## Usage

Install the plugin on your `runtimepath`, then enable the bundled `lsp/supermaven.lua` config:

```lua
vim.lsp.enable('supermaven')

vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    local client = assert(vim.lsp.get_client_by_id(args.data.client_id))
    if client.name ~= 'supermaven' then
      return
    end

    vim.lsp.inline_completion.enable(true, { client_id = client.id })
  end,
})
```

No keymaps are defined by this project. Use Neovim's built-in inline completion APIs however you prefer.

## Configuration

Override settings with `vim.lsp.config()`:

```lua
vim.lsp.config('supermaven', {
  settings = {
    supermaven = {
      tier = 'free',
      ignore_filetypes = { markdown = true },
      binary = {
        path = nil,
        download = true,
      },
    },
  },
})
```

Supported `settings.supermaven` fields:

- `tier`: `'auto'`, `'free'`, or `'pro'`.
- `ignore_filetypes`: list or map of filetypes to skip.
- `log_level`: `'off'`, `'error'`, `'warn'`, `'info'`, or `'debug'`.
- `poll_interval_ms`: how often pending agent responses are checked.
- `response_timeout_ms`: maximum wait for an inline completion response.
- `open_pro_url`: open the activation URL automatically when `tier = 'pro'`.
- `binary.path`: use an existing `sm-agent` binary.
- `binary.download`: allow auto-download when `binary.path` is unset.
- `binary.download_timeout_ms`: download timeout for `vim.net.request()`.

## Notes

- Binary downloads use `vim.net.request()`.
- Binary downloads are prefetched in the background during LSP startup.
- The server advertises `inlineCompletionProvider` and full text sync.
- `positionEncoding` is set to `utf-8` so request positions line up with Lua byte offsets.

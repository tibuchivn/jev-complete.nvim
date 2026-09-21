-- plugin/jev-complete.lua
-- Loaded once when the plugin is sourced. Nothing is set up until the user
-- calls require('jev').setup(), which registers the autocommands.

if vim.g.loaded_jev_complete then
  return
end
vim.g.loaded_jev_complete = true

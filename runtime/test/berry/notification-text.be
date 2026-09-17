# text validation must happen before copying into the fixed ipc text field.
var refused = false
try
  tc002.notify('xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx')
except ..
  refused = true
end
assert(refused, 'oversized notification text must be refused')

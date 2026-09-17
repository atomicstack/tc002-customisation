# optional queue arguments are validated before anything leaves the interpreter.
var refused = false
try
  tc002.notify('door', 0xffffff, 5, 'bad/name', true, true)
except ..
  refused = true
end
assert(refused, 'invalid notification names must be refused')

refused = false
try
  tc002.notify('door', 0xffffff, 5, 'door', 'yes', true)
except ..
  refused = true
end
assert(refused, 'stack must be a boolean')

tc002.notify('door', 0xff8000, 5, 'door', true, true)
tc002.dismiss('door')
tc002.dismiss()

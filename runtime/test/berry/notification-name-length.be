# a name may be as long as the device allows, 255 characters, and no longer.
var longest = ''
for i: 1 .. 255 longest += 'n' end
tc002.notify('door', 0xffffff, 5, longest, true, true)
tc002.dismiss(longest)

var refused = false
try
  tc002.notify('door', 0xffffff, 5, longest + 'n', true, true)
except ..
  refused = true
end
assert(refused, 'a 256-character name must be refused')

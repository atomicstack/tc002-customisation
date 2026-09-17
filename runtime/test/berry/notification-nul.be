# names must be validated as whole berry strings, not nul-terminated prefixes.
import string
var bad_name = 'door' + string.char(0) + 'bad'
assert(size(bad_name) == 8, 'fixture must contain an embedded nul')
var refused = false
try
  tc002.notify('x', 0xffffff, 5, bad_name, true, true)
except ..
  refused = true
end
assert(refused, 'a notification name containing nul must be refused')

refused = false
try
  tc002.dismiss(bad_name)
except ..
  refused = true
end
assert(refused, 'a dismissal name containing nul must be refused')

refused = false
try
  tc002.notify('hello' + string.char(0) + 'hidden')
except ..
  refused = true
end
assert(refused, 'notification text containing nul must be refused')

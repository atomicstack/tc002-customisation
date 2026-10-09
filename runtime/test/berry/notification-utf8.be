# notification text is utf-8; control characters are still refused.
import string
tc002.notify('20°C ☺')

var refused = false
try
  tc002.notify('a' + string.char(1) + 'b')
except ..
  refused = true
end
assert(refused, 'a control character in notification text must be refused')

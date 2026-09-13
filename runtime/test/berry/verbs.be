# the device verbs a script can call. each one has to leave the building as an ipc message;
# the harness records them and checks against verbs.emits.
tc002.scene('art')
tc002.brightness(40)
tc002.notify('doorbell', 0xff0000, 5)

# and the bounds are the api's own, so a script hears the same refusal an http client would
var refused = false
try
  tc002.brightness(0)
except .. 
  refused = true
end
assert(refused, 'brightness 0 must be refused')

refused = false
try
  tc002.scene('nonsense')
except ..
  refused = true
end
assert(refused, 'an unknown scene must be refused')

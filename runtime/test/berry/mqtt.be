# a script declares the topics it cares about and publishes to the broker
tc002.subscribe('home/doorbell')
tc002.subscribe('home/+/state')
tc002.publish('tc002/berry/hello', 'from a script')

# and reacts to what arrives, with the topic and payload as strings
var seen = []
tc002.on('mqtt', def (topic, payload, n) seen.push(topic + '=' + payload) end)
# a fourth argument that is not a filter must not break dispatch: this is a plain global and
# anything may call it
_tc002_dispatch('mqtt', 'home/doorbell', 'pressed', 0)
assert(seen[0] == 'home/doorbell=pressed', 'got ' + str(seen))

# an ntfy arrival lands on its own handler name
var notes = []
tc002.on('ntfy', def (topic, message, n) notes.push(message) end)
_tc002_dispatch('ntfy', '', 'the parcel is here', 0)
assert(notes[0] == 'the parcel is here', 'got ' + str(notes))

# and stops caring, which used to be impossible: a topic outlived the script that asked for it
tc002.unsubscribe("home/doorbell")

# a handler given to subscribe hears only its own filter's topics, so two scripts sharing the vm
# do not see each other's traffic. the runtime says which filter matched; berry never re-implements
# the wildcard rules.
var mine = []
var theirs = []
tc002.subscribe('home/+/temp', def (topic, payload) mine.push(topic) end)
tc002.subscribe('garden/#', def (topic, payload) theirs.push(topic) end)
_tc002_dispatch('mqtt', 'home/hall/temp', '21', 'home/+/temp')
_tc002_dispatch('mqtt', 'garden/shed/door', 'open', 'garden/#')
assert(size(mine) == 1 && mine[0] == 'home/hall/temp', 'mine ' + str(mine))
assert(size(theirs) == 1 && theirs[0] == 'garden/shed/door', 'theirs ' + str(theirs))

# and the plain tc002.on('mqtt') handler still sees everything, as it always did
assert(size(seen) == 3, 'the catch-all should still see every arrival, got ' + str(seen))

# unsubscribing takes its handler with it
tc002.unsubscribe('home/+/temp')
_tc002_dispatch('mqtt', 'home/hall/temp', '22', 'home/+/temp')
assert(size(mine) == 1, 'a dropped filter should not still fire, got ' + str(mine))

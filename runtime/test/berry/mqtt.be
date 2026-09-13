# a script declares the topics it cares about and publishes to the broker
tc002.subscribe('home/doorbell')
tc002.subscribe('home/+/state')
tc002.publish('tc002/berry/hello', 'from a script')

# and reacts to what arrives, with the topic and payload as strings
var seen = []
tc002.on('mqtt', def (topic, payload, n) seen.push(topic + '=' + payload) end)
_tc002_dispatch('mqtt', 'home/doorbell', 'pressed', 0)
assert(seen[0] == 'home/doorbell=pressed', 'got ' + str(seen))

# an ntfy arrival lands on its own handler name
var notes = []
tc002.on('ntfy', def (topic, message, n) notes.push(message) end)
_tc002_dispatch('ntfy', '', 'the parcel is here', 0)
assert(notes[0] == 'the parcel is here', 'got ' + str(notes))

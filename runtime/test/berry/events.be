# handlers register, dispatch reaches them, and a raising handler does not take the others with it
var seen = []

tc002.on('button', def (control, event, steps)
  seen.push(control + ':' + event)
end)

tc002.on('button', def (control, event, steps)
  raise 'deliberate', 'this handler always fails'
end)

tc002.on('button', def (control, event, steps)
  seen.push('third ran too')
end)

var ran = _tc002_dispatch('button', 'left', 'click', 0)
assert(ran == 2, 'two of three handlers should have completed, got ' + str(ran))
assert(seen[0] == 'left:click', 'the first handler saw the event')
assert(seen[1] == 'third ran too', 'a failing handler does not stop the ones after it')

# a handler that fails ten times in a row is dropped, so it cannot fill the log ring forever
var i = 0
while i < 10
  _tc002_dispatch('button', 'left', 'click', 0)
  i += 1
end
ran = _tc002_dispatch('button', 'left', 'click', 0)
assert(ran == 2, 'the good handlers still run')
assert(size(tc002._handlers['button']) == 2, 'the failing handler was dropped, got ' + str(size(tc002._handlers['button'])))

# timers: one repeating and one that fires once
var ticks = 0
tc002.every(100, def () ticks += 1 end)
var once = 0
tc002.after(250, def () once += 1 end)

_tc002_tick(100)
assert(ticks == 1, 'the repeating timer fired')
assert(once == 0, 'the one-shot has not come due')
_tc002_tick(100)
_tc002_tick(100)
assert(ticks == 3, 'the repeating timer keeps firing, got ' + str(ticks))
assert(once == 1, 'the one-shot fired')
assert(_tc002_timers() == 1, 'the one-shot removed itself, leaving one timer')

# the shape berryd actually calls with: the event name first, then the control and the edge.
# an earlier version of the caller passed the control as the event name, so every press looked up
# a handler list that did not exist and did nothing at all, quietly.
var shape = []
tc002.on('button', def (control, event, steps) shape.push(str(control) + '/' + str(event) + '/' + str(steps)) end)
_tc002_dispatch('button', 'middle', 'press', 0)
assert(shape[size(shape) - 1] == 'middle/press/0', 'got ' + str(shape))

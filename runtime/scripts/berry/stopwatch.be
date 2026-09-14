# stopwatch -- the right button starts it, stops it, and puts it away
#
# the three buttons report press and release and nothing else: there is no click and no long press
# on them, and the knob is the only control that reports long. so one button carries the whole
# thing, and the right button is the one to use, because selecting the canvas is what it already
# does. the press that starts the stopwatch is the press that brings the canvas up.
#
#   press   from idle     start from zero
#   press   while running  freeze the reading
#   press   while frozen   put it away and show the clock again
#
# the elapsed time is counted in timer ticks, not read from a clock, so it is as accurate as the
# timer wheel and no more. it is a kitchen timer, not a stopwatch for a race.

import string

var SW_TICK_MS = 100
var SW_RUN_COLOUR = 0x44ff88
var SW_HOLD_COLOUR = 0xffaa33

var sw_state = 'idle'
var sw_ms = 0

def sw_text()
  var tenths = int(sw_ms / 100) % 10
  var secs = int(sw_ms / 1000) % 60
  var mins = int(sw_ms / 60000)
  if mins > 99
    mins = 99
  end
  return string.format('%d:%02d.%d', mins, secs, tenths)
end

def sw_draw()
  var colour = SW_RUN_COLOUR
  if sw_state == 'hold'
    colour = SW_HOLD_COLOUR
  end
  panel.clear()
  panel.text(4, 1, sw_text(), colour)
  panel.rect(2, 11, 48, 3, 0x101010, 1)
  # the bar is the seconds hand: one sweep a minute
  var w = int((sw_ms % 60000) * 48 / 60000)
  if w > 0
    panel.rect(2, 11, w, 3, colour, 1)
  end
  panel.push()
end

tc002.on('button', def (control, event, steps)
  if control != 'right' || event != 'press'
    return
  end
  if sw_state == 'idle'
    sw_ms = 0
    sw_state = 'run'
    panel.stream()
    sw_draw()
  elif sw_state == 'run'
    sw_state = 'hold'
    sw_draw()
  else
    sw_state = 'idle'
    tc002.scene('clock')
  end
end)

tc002.every(SW_TICK_MS, def ()
  if sw_state == 'run'
    sw_ms += SW_TICK_MS
    sw_draw()
  elif sw_state == 'hold'
    # a frozen reading still has to be repushed: the frame carries a deadman, and a panel that
    # cleared itself while the user was reading it would look like a crash
    sw_draw()
  end
end)

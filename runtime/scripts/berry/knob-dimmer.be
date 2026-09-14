# knob dimmer -- turn the dial to set the panel brightness
#
# the dial is free here and nowhere else. turning it pages through clock faces on the clock base
# and art generators on the art base, but the arbiter returns early for the canvas, so a script
# that shows a canvas owns the rotary completely. press the right button first: that is the one
# that selects the canvas.
#
# the reading is pushed as a stream frame rather than installed as a canvas document. a stream
# frame is idempotent and never bumps the revision -- ten of them a second is not ten state
# changes -- and it carries its own deadman, so letting go is all it takes to clear the panel.
#
# the device never tells a script what the brightness already is, so DIM_START is what this
# believes until the first turn.

var DIM_START = 50         # the brightness this assumes at load
var DIM_STEP = 5           # percent per detent
var DIM_MIN = 5            # below about five the panel is legible only in the dark
var DIM_MAX = 100
var DIM_LINGER_MS = 1500   # how long the reading stays up after the last turn
var DIM_RETURN = true      # show the clock again once the reading has gone

var dim_level = DIM_START
var dim_left_ms = 0

def dim_draw()
  panel.clear()
  panel.text(2, 1, str(dim_level) + '%', 0xffcc44)
  panel.rect(2, 10, 48, 4, 0x202020, 1)
  var w = int(dim_level * 46 / 100)
  if w < 1
    w = 1
  end
  panel.rect(3, 11, w, 2, 0xffcc44, 1)
  panel.push()
end

def dim_set(n)
  if n < DIM_MIN
    n = DIM_MIN
  end
  if n > DIM_MAX
    n = DIM_MAX
  end
  if n == dim_level
    return
  end
  dim_level = n
  try
    tc002.brightness(dim_level)
  except .. as e, m
    print('dimmer: the brightness was refused: ' + str(m))
  end
end

tc002.on('button', def (control, event, steps)
  if control != 'rotary'
    return
  end
  # steps is the detent count for this event; anything else arrived from an injection
  var n = 1
  if type(steps) == 'int' && steps > 0 && steps <= 16
    n = steps
  end
  var delta = DIM_STEP * n
  if event == 'ccw'
    delta = -delta
  end
  dim_set(dim_level + delta)
  if dim_left_ms <= 0
    panel.stream()
  end
  dim_left_ms = DIM_LINGER_MS
  dim_draw()
end)

tc002.every(100, def ()
  if dim_left_ms <= 0
    return
  end
  dim_left_ms -= 100
  if dim_left_ms > 0
    dim_draw()
  elif DIM_RETURN
    tc002.scene('clock')
  end
end)

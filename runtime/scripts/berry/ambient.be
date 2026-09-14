# ambient -- a slow colour wash, for an evening when the clock is the only light on
#
# thirteen bands four pixels wide, drifting through the hues. it is thirteen elements, which the
# twenty-four a canvas document holds can carry comfortably, and it is pushed as stream frames so
# the revision never moves.
#
# press the right button to start or stop it. that button selects the canvas anyway, which is where
# this has to be shown, so the gesture and the side effect agree for once.

var AM_AUTO_START = false    # true takes the panel at load; false waits to be asked
var AM_FRAME_MS = 40         # twenty-five frames a second is plenty for something this slow
var AM_BANDS = 13
var AM_VALUE = 110           # 0-255, the brightest any band gets. this is ambience, not a torch
var AM_HUE_STEP = 1          # degrees of hue per frame
var AM_SPREAD = 14           # degrees of hue between one band and the next
var AM_BREATHE = true        # let the whole wash rise and fall as well as drift

var am_running = false
var am_hue = 0
var am_breath = 0
var am_up = true

# hue to rgb with no floating point and no libm: six linear segments, which is what a hue wheel is
def am_rgb(h, v)
  var hue = h % 360
  if hue < 0
    hue += 360
  end
  var region = int(hue / 60)
  var f = hue % 60
  var q = int(v * (60 - f) / 60)
  var t = int(v * f / 60)
  if region == 0
    return (v << 16) | (t << 8)
  elif region == 1
    return (q << 16) | (v << 8)
  elif region == 2
    return (v << 8) | t
  elif region == 3
    return (q << 8) | v
  elif region == 4
    return (t << 16) | v
  end
  return (v << 16) | q
end

def am_start()
  am_running = true
  am_breath = AM_VALUE
  am_up = false
  panel.stream()
end

def am_stop()
  am_running = false
  tc002.scene('clock')
end

tc002.on('button', def (control, event, steps)
  if control != 'right' || event != 'press'
    return
  end
  if am_running
    am_stop()
  else
    am_start()
  end
end)

tc002.every(AM_FRAME_MS, def ()
  if !am_running
    return
  end
  am_hue = (am_hue + AM_HUE_STEP) % 360
  var value = AM_VALUE
  if AM_BREATHE
    # a triangle wave: no sine, no libm, and at this speed the eye cannot tell the difference
    if am_up
      am_breath += 1
      if am_breath >= AM_VALUE
        am_up = false
      end
    else
      am_breath -= 1
      if am_breath <= int(AM_VALUE / 4)
        am_up = true
      end
    end
    value = am_breath
  end
  panel.clear()
  var w = int(52 / AM_BANDS)
  if w < 1
    w = 1
  end
  var i = 0
  while i < AM_BANDS
    panel.rect(i * w, 0, w, 16, am_rgb(am_hue + i * AM_SPREAD, value), 1)
    i += 1
  end
  panel.push()
end)

if AM_AUTO_START
  am_start()
end

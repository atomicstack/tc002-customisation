# pomodoro -- turn the dial to choose the length, press right to start
#
# turning the dial while nothing is running sets the length and shows it; the right button starts
# and cancels. at the end it notifies, plays a sound if there is one, and hands the panel back.
#
# sound is off by default on this device, so POM_SOUND is tried and forgiven: a clock with no
# speaker enabled still gets its notification.

import string

var POM_MINUTES = 25       # what the dial starts at
var POM_STEP = 5           # minutes per detent
var POM_MIN = 5
var POM_MAX = 60
var POM_SOUND = 'chime'    # a name from the sound store; '' for no sound
var POM_VOLUME = 0         # 0 means the device's own volume setting
var POM_TICK_MS = 250

var pom_minutes = POM_MINUTES
var pom_left_ms = 0
var pom_total_ms = 0
var pom_linger_ms = 0

def pom_draw(label, colour, filled)
  panel.clear()
  panel.text(3, 1, label, colour)
  panel.rect(2, 11, 48, 3, 0x101010, 1)
  var w = int(filled * 48)
  if w > 48
    w = 48
  end
  if w > 0
    panel.rect(2, 11, w, 3, colour, 1)
  end
  panel.push()
end

def pom_running_label()
  var left = pom_left_ms
  if left < 0
    left = 0
  end
  var secs = int(left / 1000) % 60
  var mins = int(left / 60000)
  return string.format('%d:%02d', mins, secs)
end

def pom_finish()
  pom_left_ms = 0
  pom_total_ms = 0
  tc002.notify('time up', 0xff4444, 10)
  if POM_SOUND != ''
    try
      tc002.play(POM_SOUND, POM_VOLUME, false)
    except .. as e, m
      print('pomodoro: the sound did not play: ' + str(m))
    end
  end
  tc002.scene('clock')
end

tc002.on('button', def (control, event, steps)
  if control != 'right' || event != 'press'
    return
  end
  if pom_total_ms > 0
    # cancel
    pom_left_ms = 0
    pom_total_ms = 0
    pom_linger_ms = 0
    tc002.scene('clock')
    tc002.notify('cancelled', 0xffaa33, 3)
  else
    pom_total_ms = pom_minutes * 60000
    pom_left_ms = pom_total_ms
    pom_linger_ms = 0
    panel.stream()
    pom_draw(pom_running_label(), 0xff8844, 1.0)
  end
end)

tc002.on('button', def (control, event, steps)
  if control != 'rotary' || pom_total_ms > 0
    return
  end
  var n = 1
  if type(steps) == 'int' && steps > 0 && steps <= 16
    n = steps
  end
  var delta = POM_STEP * n
  if event == 'ccw'
    delta = -delta
  end
  pom_minutes += delta
  if pom_minutes < POM_MIN
    pom_minutes = POM_MIN
  end
  if pom_minutes > POM_MAX
    pom_minutes = POM_MAX
  end
  if pom_linger_ms <= 0
    panel.stream()
  end
  pom_linger_ms = 1500
  pom_draw(str(pom_minutes) + ' min', 0x66ccff, real(pom_minutes) / POM_MAX)
end)

tc002.every(POM_TICK_MS, def ()
  if pom_total_ms > 0
    pom_left_ms -= POM_TICK_MS
    if pom_left_ms <= 0
      pom_finish()
    else
      pom_draw(pom_running_label(), 0xff8844, real(pom_left_ms) / pom_total_ms)
    end
  elif pom_linger_ms > 0
    pom_linger_ms -= POM_TICK_MS
    if pom_linger_ms > 0
      pom_draw(str(pom_minutes) + ' min', 0x66ccff, real(pom_minutes) / POM_MAX)
    else
      tc002.scene('clock')
    end
  end
end)

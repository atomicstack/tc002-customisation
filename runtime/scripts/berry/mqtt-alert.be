# mqtt alert -- something needs you now, and the whole panel says so
#
# publish anything but a clear word to the topic and the panel flashes it; publish one of AT_CLEAR
# (or press any button) and it stops. the flash is pushed as stream frames rather than installed as
# a canvas document, which is the right tool twice over: a stream frame never bumps the revision,
# so four flashes a second do not become four state changes a second, and a button press clears a
# stream frame by itself -- the dismissal is free.

import time

var AT_TOPIC = 'home/alert'
var AT_SECONDS = 30           # give up flashing after this long
var AT_FLASH_MS = 250
var AT_COLOUR = 0xff2222
var AT_TEXT_COLOUR = 0xffffff
var AT_SOUND = ''             # a name from the sound store; '' for a silent alert
var AT_VOLUME = 0
var AT_NOTIFY = true          # also raise the runtime's own notification overlay
var AT_CLEAR = ['', 'clear', 'off', 'ok', 'none', '0', 'false']

var at_left_ms = 0
var at_text = ''
var at_on = false

def at_is_clear(payload)
  for c : AT_CLEAR
    if payload == c
      return true
    end
  end
  return false
end

def at_stop()
  if at_left_ms <= 0
    return
  end
  at_left_ms = 0
  if AT_SOUND != ''
    try
      tc002.stop_sound()
    except .. as e, m
      print('alert: the sound would not stop: ' + str(m))
    end
  end
  tc002.scene('clock')
end

tc002.subscribe(AT_TOPIC, def (topic, payload)
  if type(payload) != 'string'
    return
  end
  if at_is_clear(payload)
    at_stop()
    return
  end
  at_text = payload
  if size(at_text) > 8
    at_text = at_text[0 .. 7]
  end
  var was_quiet = at_left_ms <= 0
  at_left_ms = AT_SECONDS * 1000
  if was_quiet
    panel.stream()
    if AT_SOUND != ''
      try
        tc002.play(AT_SOUND, AT_VOLUME, true)
      except .. as e, m
        print('alert: the sound did not play: ' + str(m))
      end
    end
  end
  if AT_NOTIFY
    tc002.notify(at_text, AT_COLOUR, 5)
  end
end)

tc002.on('button', def (control, event, steps)
  if event == 'press'
    at_stop()
  end
end)

tc002.every(AT_FLASH_MS, def ()
  if at_left_ms <= 0
    return
  end
  at_left_ms -= AT_FLASH_MS
  if at_left_ms <= 0
    at_stop()
    return
  end
  at_on = !at_on
  panel.clear()
  if at_on
    panel.rect(0, 0, 52, 16, AT_COLOUR, 1)
  end
  panel.text(2, 5, at_text, AT_TEXT_COLOUR)
  panel.push()
end)

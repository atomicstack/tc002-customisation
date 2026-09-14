# alarm -- wake at a local time, with the panel coming up before the sound does
#
# the device clock is utc. the runtime applies your timezone in zig and berryd is execve'd with an
# empty environment, so berry's localtime has no TZ to read: the offset below is how this script
# knows what the local hour is. a fixed offset does not follow daylight saving.
#
#   left button      stop until tomorrow
#   right or middle  snooze
#
# the brightness ramp is the useful part -- the panel lights gradually over the first minute, which
# wakes a room more kindly than a sound does. the script does not know what the brightness was
# before it started, so it cannot put it back; set AL_AFTER if you want a known level afterwards.

import string
import time

var AL_HOUR = 7
var AL_MINUTE = 15
var AL_DAYS = [1, 2, 3, 4, 5]   # 0 is sunday; an empty list means every day
var AL_UTC_OFFSET_MIN = 120     # your local offset from utc, in minutes
var AL_SOUND = 'alarm'          # a name from the sound store; '' for a silent alarm
var AL_VOLUME = 60
var AL_RING_S = 120             # give up ringing after this long
var AL_SNOOZE_MIN = 9
var AL_BRIGHT_FROM = 10
var AL_BRIGHT_TO = 90
var AL_RAMP_S = 60              # how long the brightness takes to climb
var AL_AFTER = 0                # brightness to leave behind, or 0 to leave it where it ended

var al_ring_ms = 0
var al_fired = ''
var al_snooze_at = 0
var al_flash = false

def al_local()
  var now = time.time()
  # an unsynced clock reads as january 1970 and would ring the moment the hour matched
  if now < 1600000000
    return nil
  end
  return time.dump(now + AL_UTC_OFFSET_MIN * 60)
end

def al_day_allowed(wd)
  if size(AL_DAYS) == 0
    return true
  end
  for d : AL_DAYS
    if d == wd
      return true
    end
  end
  return false
end

def al_bright(n)
  if n < 1
    n = 1
  end
  if n > 100
    n = 100
  end
  try
    tc002.brightness(n)
  except .. as e, m
    print('alarm: the brightness was refused: ' + str(m))
  end
end

def al_start()
  al_ring_ms = 0
  al_snooze_at = 0
  al_bright(AL_BRIGHT_FROM)
  panel.stream()
  if AL_SOUND != ''
    try
      tc002.play(AL_SOUND, AL_VOLUME, true)
    except .. as e, m
      print('alarm: the sound did not play: ' + str(m))
    end
  end
end

def al_stop()
  al_ring_ms = -1
  try
    tc002.stop_sound()
  except .. as e, m
    print('alarm: the sound would not stop: ' + str(m))
  end
  if AL_AFTER > 0
    al_bright(AL_AFTER)
  end
  tc002.scene('clock')
end

tc002.on('button', def (control, event, steps)
  if al_ring_ms < 0 || event != 'press'
    return
  end
  if control == 'left'
    al_stop()
  elif control == 'right' || control == 'middle'
    al_snooze_at = time.time() + AL_SNOOZE_MIN * 60
    al_stop()
    tc002.notify('snooze', 0x66ccff, 3)
  end
end)

# the minute check. every ten seconds is often enough for a one-minute window and cheap enough to
# be invisible.
tc002.every(10000, def ()
  var now = time.time()
  if al_snooze_at > 0 && now >= al_snooze_at
    al_start()
    return
  end
  if al_ring_ms >= 0
    return
  end
  var t = al_local()
  if t == nil
    return
  end
  var key = string.format('%d-%d-%d', t['year'], t['month'], t['day'])
  if t['hour'] != AL_HOUR || t['min'] != AL_MINUTE
    return
  end
  if !al_day_allowed(t['weekday']) || al_fired == key
    return
  end
  al_fired = key
  al_start()
end)

tc002.every(250, def ()
  if al_ring_ms < 0
    return
  end
  al_ring_ms += 250
  if al_ring_ms >= AL_RING_S * 1000
    al_stop()
    return
  end
  var climbed = AL_BRIGHT_TO - AL_BRIGHT_FROM
  var through = real(al_ring_ms) / (AL_RAMP_S * 1000)
  if through > 1.0
    through = 1.0
  end
  al_bright(AL_BRIGHT_FROM + int(climbed * through))
  al_flash = !al_flash
  var colour = 0xff6622
  if al_flash
    colour = 0xffdd66
  end
  panel.clear()
  panel.rect(0, 0, 52, 16, 0x140800, 1)
  panel.text(4, 5, 'wake up', colour)
  panel.push()
end)

# nothing is ringing until the clock says so
al_ring_ms = -1

# night mode -- dim the panel between two local hours, and put the clock back up
#
# the device clock is utc (berryd gets an empty environment, so berry's localtime has no TZ), which
# is why the hours below are converted with an explicit offset. a fixed offset does not follow
# daylight saving.
#
# it only ever acts on a change, so it does not fight you: set the brightness by hand at midnight
# and it stays where you put it until the next boundary.

import time

var NM_FROM_HOUR = 22       # night starts at this local hour
var NM_TO_HOUR = 7          # and ends at this one
var NM_NIGHT = 10           # brightness through the night
var NM_DAY = 70             # and through the day
var NM_UTC_OFFSET_MIN = 120
var NM_NIGHT_BASE = 'clock' # what to show at night; '' to leave the base alone
var NM_ANNOUNCE = false     # notify on each change, which is useful while you are tuning it

var nm_state = ''

def nm_is_night(hour)
  if NM_FROM_HOUR == NM_TO_HOUR
    return false
  end
  if NM_FROM_HOUR < NM_TO_HOUR
    return hour >= NM_FROM_HOUR && hour < NM_TO_HOUR
  end
  # the ordinary case: the window crosses midnight
  return hour >= NM_FROM_HOUR || hour < NM_TO_HOUR
end

def nm_check()
  var now = time.time()
  # an unsynced clock reads as january 1970 and would put the panel into night at every boot
  if now < 1600000000
    return
  end
  var t = time.dump(now + NM_UTC_OFFSET_MIN * 60)
  var want = 'day'
  if nm_is_night(t['hour'])
    want = 'night'
  end
  if want == nm_state
    return
  end
  nm_state = want
  var level = NM_DAY
  if want == 'night'
    level = NM_NIGHT
  end
  try
    tc002.brightness(level)
  except .. as e, m
    print('night mode: the brightness was refused: ' + str(m))
  end
  if want == 'night' && NM_NIGHT_BASE != ''
    try
      tc002.scene(NM_NIGHT_BASE)
    except .. as e, m
      print('night mode: the scene was refused: ' + str(m))
    end
  end
  if NM_ANNOUNCE
    tc002.notify(want, 0x6688ff, 3)
  end
end

nm_check()
tc002.every(60000, nm_check)

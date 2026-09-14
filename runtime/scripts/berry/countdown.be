# countdown -- days, hours and minutes until a date you care about
#
# the device clock is utc: the runtime applies your timezone itself, in zig, and berryd is execve'd
# with an empty environment, so there is no TZ for berry's localtime to read. that is why the date
# below is written in your local time and converted with an explicit offset rather than guessed.
# a fixed offset does not know about daylight saving -- change it twice a year, or accept an hour.
#
# this draws a canvas document rather than pushing frames: it changes once a minute, and a document
# the renderer owns costs nothing between changes. it only shows while the canvas is the base, so
# press the right button to see it -- or set CD_TAKE_OVER to have the script do that itself.

import string
import time

var CD_LABEL = 'holiday'        # eight characters fit across the panel in this face
var CD_YEAR = 2026
var CD_MONTH = 12
var CD_DAY = 25
var CD_HOUR = 9
var CD_MINUTE = 0
var CD_UTC_OFFSET_MIN = 120     # your local offset from utc, in minutes
var CD_COLOUR = 0x66ccff
var CD_DONE_COLOUR = 0x44ff88
var CD_TAKE_OVER = false        # select the canvas at load rather than waiting to be asked

# days since 1970-01-01 for a civil date, by howard hinnant's method: shift the year to start in
# march so the leap day lands at the end of it, and no month table is needed.
def cd_days(y, m, d)
  var yy = y
  if m <= 2
    yy -= 1
  end
  var era = int(yy / 400)
  var yoe = yy - era * 400
  var mp = m - 3
  if m <= 2
    mp = m + 9
  end
  var doy = int((153 * mp + 2) / 5) + d - 1
  var doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

# the one piece of arithmetic here that can be silently wrong, checked where it is defined. a wrong
# answer would look like a plausible countdown, which is the worst kind.
assert(cd_days(1970, 1, 1) == 0 && cd_days(2000, 3, 1) == 11017 && cd_days(2024, 2, 29) == 19782,
  'the civil-date arithmetic is wrong')

var cd_target = cd_days(CD_YEAR, CD_MONTH, CD_DAY) * 86400 + CD_HOUR * 3600 + CD_MINUTE * 60 - CD_UTC_OFFSET_MIN * 60
var cd_shown = ''

def cd_remaining(left)
  if left <= 0
    return 'done'
  end
  var days = int(left / 86400)
  var hours = int(left / 3600) % 24
  var mins = int(left / 60) % 60
  var secs = left % 60
  if days > 0
    return string.format('%dd %02dh', days, hours)
  end
  if hours > 0
    return string.format('%dh %02dm', hours, mins)
  end
  return string.format('%dm %02ds', mins, secs)
end

def cd_draw()
  var now = time.time()
  # an unsynced clock reads as 1970 and would count down to a date fifty years in its future
  if now < 1600000000
    return
  end
  var text = cd_remaining(cd_target - now)
  if text == cd_shown
    return
  end
  cd_shown = text
  var colour = CD_COLOUR
  if text == 'done'
    colour = CD_DONE_COLOUR
  end
  panel.clear()
  panel.text(2, 1, CD_LABEL, 0x808080)
  panel.text(2, 9, text, colour)
  panel.show()
end

if CD_TAKE_OVER
  tc002.scene('canvas')
end
cd_draw()
tc002.every(15000, cd_draw)

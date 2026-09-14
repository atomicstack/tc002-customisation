# signal light -- a build, a deploy or an agent, as a colour you can see from the doorway
#
# one topic, one word, one colour. the panel is fifty-two by sixteen and this uses all of it, which
# is the point: the reading is the colour, and the word underneath is only there when you are close
# enough to want the detail.
#
# it draws a canvas document rather than pushing frames. a state that changes a few times an hour
# does not need sixty frames a second, and a document costs nothing between changes.

import string
import time

var SG_TOPIC = 'dev/ci/state'
var SG_TAKE_OVER = false
var SG_UNKNOWN_COLOUR = 0x303030

# the word on the topic -> [band colour, what to write, text colour]
var SG_STATES = {
  'idle': [0x0a1420, 'idle', 0x506070],
  'queued': [0x2a2a00, 'queue', 0xaaaa44],
  'running': [0x3a2200, 'run', 0xffaa33],
  'passed': [0x043a12, 'pass', 0x44ff88],
  'pass': [0x043a12, 'pass', 0x44ff88],
  'success': [0x043a12, 'pass', 0x44ff88],
  'failed': [0x3a0404, 'fail', 0xff5555],
  'fail': [0x3a0404, 'fail', 0xff5555],
  'error': [0x3a0404, 'fail', 0xff5555],
  'blocked': [0x24003a, 'wait', 0xbb88ff],
  'waiting': [0x24003a, 'wait', 0xbb88ff]
}

var sg_state = ''
var sg_at = 0

def sg_draw()
  var entry = SG_STATES.find(sg_state, nil)
  panel.clear()
  if entry == nil
    panel.rect(0, 0, 52, 16, SG_UNKNOWN_COLOUR, 1)
    var text = sg_state
    if size(text) == 0
      text = '?'
    end
    if size(text) > 8
      text = text[0 .. 7]
    end
    panel.text(2, 5, text, 0x909090)
    panel.show()
    return
  end
  panel.rect(0, 0, 52, 16, entry[0], 1)
  panel.rect(0, 0, 52, 2, entry[2], 1)
  panel.text(2, 6, entry[1], entry[2])
  panel.show()
end

tc002.subscribe(SG_TOPIC, def (topic, payload)
  if type(payload) != 'string'
    return
  end
  var next = string.tolower(payload)
  if size(next) > 16
    next = next[0 .. 15]
  end
  if next == sg_state
    return
  end
  sg_state = next
  sg_at = time.time()
  sg_draw()
end)

if SG_TAKE_OVER
  tc002.scene('canvas')
end
sg_draw()

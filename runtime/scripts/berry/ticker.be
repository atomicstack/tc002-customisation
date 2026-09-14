# ticker -- a scrolling message, because eight characters is not a sentence
#
# a script gets one font: the five-by-seven face, eight characters across a fifty-two pixel panel.
# that is enough for a reading and nowhere near enough for a notification, so this scrolls instead.
# ntfy messages and an mqtt topic both queue up here and cross the panel one after another.
#
# scrolling means a frame every thirty milliseconds, which is what `panel.stream()` and
# `panel.push()` are for: a stream frame is idempotent, never bumps the revision, and carries a
# deadman so the panel clears itself if the script dies mid-message. installing a canvas document
# thirty times a second would instead be thirty state changes a second, and every mirror watching
# the event stream would see them.

var TK_TOPIC = 'home/ticker'   # '' to leave mqtt out of it
var TK_FROM_NTFY = true        # ntfy messages scroll too, when tc002-ntfy is running
var TK_FRAME_MS = 33           # about thirty frames a second
var TK_SPEED_PX = 1            # pixels per frame; two is brisk, three is unreadable
var TK_COLOUR = 0x66ccff
var TK_ROW = 5
var TK_MAX_QUEUE = 8           # older messages are dropped when the queue is full
var TK_MAX_CHARS = 120         # a payload may be nearly four kilobytes; a marquee is not for that
var TK_REPEAT = 1              # how many times each message crosses

var tk_queue = []
var tk_text = nil
var tk_x = 52
var tk_width = 0
var tk_passes = 0

def tk_next()
  if size(tk_queue) == 0
    tk_text = nil
    tc002.scene('clock')
    return
  end
  tk_text = tk_queue[0]
  tk_queue.remove(0)
  # five pixels of glyph and one of gap, so six per character
  tk_width = 6 * size(tk_text)
  tk_x = 52
  tk_passes = TK_REPEAT
  if tk_passes < 1
    tk_passes = 1
  end
end

def tk_add(text)
  if type(text) != 'string'
    return
  end
  var t = text
  if size(t) > TK_MAX_CHARS
    t = t[0 .. TK_MAX_CHARS - 1]
  end
  if size(t) == 0
    return
  end
  var idle = tk_text == nil
  if size(tk_queue) >= TK_MAX_QUEUE
    tk_queue.remove(0)
  end
  tk_queue.push(t)
  if idle
    panel.stream()
    tk_next()
  end
end

if TK_TOPIC != ''
  tc002.subscribe(TK_TOPIC, def (topic, payload)
    tk_add(payload)
  end)
end

if TK_FROM_NTFY
  # ntfy has no topic here, so the message is the second argument
  tc002.on('ntfy', def (topic, message, n)
    tk_add(message)
  end)
end

tc002.every(TK_FRAME_MS, def ()
  if tk_text == nil
    return
  end
  panel.clear()
  panel.text(tk_x, TK_ROW, tk_text, TK_COLOUR)
  panel.push()
  tk_x -= TK_SPEED_PX
  if tk_x < -tk_width
    tk_passes -= 1
    if tk_passes > 0
      tk_x = 52
    else
      tk_next()
    end
  end
end)

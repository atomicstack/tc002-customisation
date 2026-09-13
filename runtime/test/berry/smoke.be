# the interpreter is alive and the trimmed module set is what we asked for
assert(1 + 1 == 2, 'arithmetic')

import string
assert(string.format('%d-%s', 42, 'ok') == '42-ok', 'the string module')

import json
assert(json.dump({'a': 1}) == '{"a":1}', 'the json module')

import math
assert(math.abs(-3) == 3, 'the math module')

var l = [3, 1, 2]
l.push(4)
l.reverse()
assert(str(l) == '[4, 2, 1, 3]', 'lists')
assert(l.size() == 4, 'list size')
assert(l.find(2) == 1, 'list find')

var m = {'a': 1, 'b': 2}
assert(m['b'] == 2, 'maps')
assert(m.contains('a'), 'map contains')

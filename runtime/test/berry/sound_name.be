# a name that is not a name is refused rather than quietly ignored -- the same rule
# as tc002.brightness(0), which raises instead of clamping
try
  tc002.play('no spaces here')
  print('not reached')
except .. as e
  print('refused a bad name')
end
try
  tc002.play('chime', 999)
  print('not reached')
except .. as e
  print('refused a bad volume')
end

#
# Nim i3 status bar - readline with timeout
#

from posix import Timeval, select, TFdSet, FD_SET, FD_ZERO

proc timeValFromMilliseconds(timeout: int): Timeval =
  let seconds = timeout div 1000
  result.tv_sec = seconds.int32
  result.tv_usec = ((timeout - seconds * 1000) * 1000).int32

proc readLine*(f: File, timeout:int): TaintedString =
  result = ""
  var rd: TFdSet
  FD_SET(f.getFileHandle, rd)

  var tv = timeValFromMilliseconds(timeout)
  var data_available = int(select(cint(f.getFileHandle+1), addr(rd), nil, nil, addr(tv)))
  if data_available == 0:
    return nil

  # read until newline
  while true:
    let c = f.readChar()
    if c == '\x0A':
      return result
    result.add(c)

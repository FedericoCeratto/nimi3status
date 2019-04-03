#
# Nim i3 status bar
#
# Released under GPLv3, see LICENSE file
#

import asyncdispatch,
  json,
  logging,
  marshal,
  os,
  strutils,
  times

from math import sum
from osproc import startProcess, execCmdEx, Process, peekExitCode, waitForExit
from posix import statvfs, Statvfs
from readline_timeout import readLine
from sequtils import mapIt, map, zip, keepIf
from unicode import runeLen

from colorsys import hlsToRgb


newFileLogger("nimi3status.log", fmtStr = verboseFmtStr, bufSize=0).addHandler

const
  progress_bar_items = ["▏", "▎", "▍", "▌", "▋", "▊", "▉"]
  notify_send_binpath = "/usr/bin/notify-send"
  aplay_binpath = "/usr/bin/aplay"
  amixer_binpath = "/usr/bin/amixer"
  redshift_binpath = "/usr/bin/redshift"

type ProcessPool = seq[Process]

var process_pool: ProcessPool = @[]

proc remove_zombie_processes() =
  keepIf process_pool,
    proc(p: Process): bool =
      if p.peekExitCode() == -1:
        true  # still running
      else:
        discard p.waitForExit()
        false

type MouseButton {.pure.} = enum Unknown, Left, Middle, Right, WheelUp,
  WheelDown, WheelLeft, WheelRight


proc button(event: JsonNode): MouseButton =
  MouseButton(event["button"].getInt)

proc col(h, s, l: int): string =
  ## Generate color from HSL
  let rgb = hlsToRgb(@[h.float / 360, l.float / 100, s.float / 100])
  return "#$#$#$#" % rgb.mapIt(int(it * 256).toHex(2))


proc generate_bar(perc: float, width: int): string =
  ## Generate text bar
  let items_cnt = progress_bar_items.len
  var bar_val = perc * width.float
  result = ""

  while bar_val > 0:
    var selector = (bar_val * items_cnt.float).int
    selector = min(selector, items_cnt - 1)
    result.add progress_bar_items[selector]
    bar_val -= 1

  while result.runeLen < width:
    result.add " "

  result = "[$#]" % result

proc send_notification(msg: string) =
    process_pool.add startProcess(notify_send_binpath, ".", [msg])

# Module

type Module = ref object of RootObj
    color, full_text, name: string
    cache_duration: float
    last_update_time: float

proc gen_out_line(m: Module): string  =
    """{"color": "$#", "name": "$#", "full_text": "$#"}""" % [m.color, m.name, m.full_text]

proc should_update(self: Module): bool =
  ## Check if the update method should be run or the cached value is still warm
  if self.cache_duration == 0:
    return
  let t = epochTime()
  if self.last_update_time + self.cache_duration < t:
    self.last_update_time = t
    return true

  return false

{.push base.}

method update(self: Module) = discard

method process_input(self: Module, event: JsonNode) = discard

{.pop.}

# Pomodoro

type PomodoroStatus {.pure.} = enum WaitingToStart, Running, EndOfRun, inBreak
type Pomodoro = ref object of Module
    endtime: float
    time_window: int
    num_progress_bars: int
    status: PomodoroStatus
    end_sound_fname: string
    conf: JsonNode

proc newPomodoro(c: JsonNode): Pomodoro =
  let self = Pomodoro(name: "pomodoro", color: "", full_text: "")
  self.conf = c
  self.status = PomodoroStatus.WaitingToStart
  self.time_window = 60 * 25
  self.endtime = 0
  self.num_progress_bars = 5
  self.end_sound_fname = self.conf["end_sound_fname"].str
  return self

proc notify(self: Pomodoro, msg_name: string) =
  ## Send desktop notification
  if self.conf.hasKey(msg_name):
    send_notification(self.conf[msg_name].str)

proc play_sound(self: Pomodoro, snd_name: string) =
  if self.conf.hasKey(snd_name):
    process_pool.add startProcess(aplay_binpath, ".", ["-N", self.conf[snd_name].str])

method update(self: Pomodoro) =
  var barblock = ""

  case self.status:
  of PomodoroStatus.WaitingToStart:
    barblock = "[-----]"
    self.color = ""

  of PomodoroStatus.Running:
    let remaining_time = self.endtime - epochTime()
    if remaining_time <= 0:
      self.status = PomodoroStatus.EndOfRun
      barblock = "[ end ]"
      self.color = ""
      self.notify("end_notification_msg")
      self.play_sound("end_sound_fname")

    else:
      let remaining_time = self.endtime - epochTime()
      let perc = remaining_time / self.time_window.float
      barblock = generate_bar(perc, 5)
      self.color = col(150, 50, 50)

  of PomodoroStatus.EndOfRun:
    barblock = "[ end ]"
    self.color = ""

  of PomodoroStatus.inBreak:
    barblock = "break"
    self.color = "#770000"

  self.full_text = "$#" % barblock

proc handle_click(self: Pomodoro, button: MouseButton) =
  ## Mouse click on Pomodoro
  case self.status:
  of PomodoroStatus.WaitingToStart:
    if button == MouseButton.Left:
      self.status = PomodoroStatus.Running
      self.endtime = self.time_window.float + epochTime()
      self.notify("start_notification_msg")
      self.play_sound("start_sound_fname")
  of PomodoroStatus.Running:
    if button == MouseButton.Right:
      self.status = PomodoroStatus.WaitingToStart
  of PomodoroStatus.EndOfRun:
    self.status = PomodoroStatus.inBreak
  of PomodoroStatus.inBreak:
    if button == MouseButton.Right:
      self.status = PomodoroStatus.WaitingToStart


# Clock

type Clock = ref object of Module

proc newClock(c: JsonNode): Clock =
  Clock(name: "clock", color: "")

method update(self: Clock) =
  self.full_text = now().format("yyyy-MM-dd HH:mm:ss")

method process_input(pomodoro: Pomodoro, j: JsonNode) =
  # Process input
  #
  # Example of JSON input on click:
  # {"name":"pomodoro","instance":"","button":1,"x":904,"y":888}
  if j.hasKey("name"):
    if j["name"].str == "pomodoro" or j["name"].str == "pomodoro2":
      pomodoro.handle_click(j.button)


# FreeDiskSpace

type FreeDiskSpace = ref object of Module
  path: string
  symbol: string

proc newFreeDiskSpace(c: JsonNode): FreeDiskSpace =
  result = FreeDiskSpace(name: c["name"].str, color: "", full_text: "")
  result.path = c["path"].str
  result.symbol = c["symbol"].str

method update(self: FreeDiskSpace) =
  var sfs: Statvfs
  discard statvfs(self.path.cstring, sfs)
  let free = sfs.f_frsize.int * sfs.f_blocks.int / 1073741824
  self.full_text = "$# $# GB" % [self.symbol, $free.int]


# CPU

type CPU = ref object of Module
  path: string
  symbol: string
  load_values: seq[int]

proc newCPU(c: JsonNode): CPU =
  result = CPU(name: c["name"].str, color: "", full_text: "")
  result.symbol = c["symbol"].str
  result.color = col(0, 0, 40)

method update(self: CPU) =
  for line in lines("/proc/stat"):
    if not line.strip.startswith("cpu "):
      continue

    # user: Time spent executing user applications (user mode).
    # nice: Time spent executing user applications with low priority (nice).
    # system: Time spent executing system calls (system mode).
    # idle: Idle time.
    # iowait: Time waiting for I/O operations to complete.
    # irq: Time spent servicing interrupts.
    # softirq: Time spent servicing soft-interrupts.
    # steal, guest: Used in virtualization setups.
    let new_l = line.splitWhitespace()[1..5].map(parseInt)
    if self.load_values.len == 0:
      self.load_values = new_l
      return

    let deltas = zip(new_l, self.load_values).mapIt(it[0] - it[1])
    let total = deltas[0..3].sum()
    let cpu_load = float(total - deltas[3]) / float(total)
    self.full_text = "$# $#" % [self.symbol, generate_bar(cpu_load, 2)]
    self.load_values = new_l
    return

  self.full_text = "$# [?]" % [self.symbol]


# Battery

type Battery = ref object of Module
  path: string

proc newBattery(c: JsonNode): Battery =
  result = Battery(name: c["name"].str, color: "", full_text: "")
  result.path = c["path"].str

method update(self: Battery) =
  let full = readFile("/sys/class/power_supply/$#/energy_full" % self.path).strip.parseInt
  let now = readFile("/sys/class/power_supply/$#/energy_now" % self.path).strip.parseInt
  let status = readFile("/sys/class/power_supply/$#/status" % self.path).strip
  let arrow = if status == "Discharging": "▾" else: "▴"
  self.full_text = "$# $#" % [arrow, generate_bar(now/full, 3)]
  let sat = int(max(0, now/full * -400 + 100))
  self.color = col(0, sat, 60)


# Temperature

type Temperature = ref object of Module
  path: string

proc newTemperature(c: JsonNode): Temperature =
  result = Temperature(name: c["name"].str, color: "", full_text: "")
  result.path = c["path"].str

method update(self: Temperature) =
  let temp = readFile(self.path).strip.parseInt
  self.full_text = "$# $#" % [self.name, $int(temp / 1000)]


# PlayerControl

type PlayerControl = ref object of Module
  volume_tick: int

proc newPlayerControl(c: JsonNode): PlayerControl =
  result = PlayerControl(name: c["name"].str, color: "", full_text: "▸")
  result.volume_tick = c["volume_tick"].getInt

method update(self: PlayerControl) =
  discard

proc get_volume(self: PlayerControl): float =
  # Example:
  # Simple mixer control 'Master',0
  #   Capabilities: pvolume pvolume-joined pswitch pswitch-joined
  #   Playback channels: Mono
  #   Limits: Playback 0 - 87
  #   Mono: Playback 53 [61%] [-25.50dB] [on]

  try:
    let o = execCmdEx(amixer_binpath & " sget Master")[0].splitlines()
    let chunks = o[o.len-2].strip().splitWhitespace()
    let vol_block = chunks[chunks.len-2]  # example: [61%]
    doAssert vol_block.startswith("[")
    doAssert vol_block.endswith("%]")
    result = vol_block[1..<len(vol_block)-2].parseFloat / 100.0
  except:
    error getCurrentExceptionMsg()
    result = 0


method process_input(self: PlayerControl, event: JsonNode) =
  # Example input
  # {"name":"player","instance":"","button":4}

  # Reset to normal
  self.color = ""
  self.full_text = "▸"

  var delta = "$#%" % $self.volume_tick
  case event.button
  of MouseButton.WheelUp:
    delta.add "+"
    self.color = col(120, 99, 40)
    self.full_text = self.get_volume.generate_bar(3) & " ▸"
  of MouseButton.WheelDown:
    delta.add "-"
    self.color = col(0, 99, 40)
    self.full_text = self.get_volume.generate_bar(3) & " ▸"
  else:
    return

  process_pool.add startProcess(amixer_binpath, ".", ["-q", "sset", "Master", delta])


# Network

type Network = ref object of Module

proc newNetwork(name="network"): Network =
  result = Network(name: name, color: "", full_text: "", cache_duration:5)

method update(self: Network) =
  if not self.should_update:
    return

  let essid = execCmdEx("/sbin/iwgetid -r")[0].strip
  if essid.len == 0:
    self.full_text = ""
    return

  for line in lines("/proc/net/wireless"):
    if line.strip.startswith("wlan"):
      let quality = line.splitWhitespace[2]
      self.full_text = "$# $#" % [essid, quality]


# Memory

type Memory = ref object of Module

proc newMemory(): Memory =
  result = Memory(name: "memory", color: "", full_text: "")

method update(self: Memory) =
  var total, used: int
  for line in lines("/sys/devices/system/node/node0/meminfo"):
    if line.contains "MemTotal":
      total = line.splitWhitespace()[3].parseInt
    if line.contains "MemUsed":
      used = line.splitWhitespace()[3].parseInt

  let perc = used.float / total.float
  self.full_text = generate_bar(perc, 5)
  let sat = int(max(0, perc * 600 - 500))
  self.color = col(0, sat, 60)


# Swap

type Swap = ref object of Module

proc newSwap(c: JsonNode): Swap =
  result = Swap(name: c["name"].str, color: "", full_text: c["label"].str)

method update(self: Swap) =
  var total, used, free: int
  for line in lines("/proc/meminfo"):
    # SwapTotal:        975868 kB
    if line.startswith("SwapTotal"):
      total = line.splitWhitespace()[1].parseInt
    elif line.startswith("SwapFree"):
      free = line.splitWhitespace()[1].parseInt

  let perc = (total.float - free.float) / total.float
  self.full_text = "$# $#" % [self.name, generate_bar(perc, 5)]
  let sat = int(max(0, perc * 600 - 500))
  self.color = col(0, sat, 60)


# FileCheck

type FileCheck = ref object of Module
  path: string
  when_found: string
  when_not_found: string

proc newFileCheck(path, when_found, when_not_found: string): FileCheck =
  result = FileCheck(name: "filecheck", color: "", full_text: "", when_found: when_found,
    when_not_found: when_not_found, path: path)

method update(self: FileCheck) =
  self.full_text = if fileExists(self.path): self.when_found else: self.when_not_found


# NetworkTraffic

type NetworkTraffic = ref object of Module
  iface_name: string
  when_found: string
  when_not_found: string
  when_not_found_color: string
  rx_pkts: int
  rtx_pkts: int
  max_bw: int

proc newNetworkTraffic(c: JsonNode): NetworkTraffic =
  ## Interface status, blink on network traffic
  result = NetworkTraffic(name: c["name"].str, color: "", full_text: "",
    when_found: c["when_up"].str,
    when_not_found: c["when_down"].str,
    iface_name: c["iface"].str,
    rx_pkts: 0,
    rtx_pkts: 0,
    max_bw: c["max_bw"].getInt
  )
  result.when_not_found_color =
    if c.hasKey("when_down_color"):
      c["when_down_color"].str
    else:
      ""

method update(self: NetworkTraffic) =
  let basedir = "/sys/class/net/$#" % self.iface_name
  if not dirExists(basedir):
    self.full_text = self.when_not_found
    self.color = self.when_not_found_color
    return

  self.full_text = self.when_found
  let rx_pkts = readFile("$#/statistics/rx_packets" % basedir).strip.parseInt
  let delta = rx_pkts - self.rx_pkts
  self.rx_pkts = rx_pkts
  let lum = min(49, max(0, 10 * delta))
  self.color = col(0, 0, lum)

  if self.max_bw != 0:
    let rtx_pkts = rx_pkts +
      readFile("$#/statistics/tx_packets" % basedir).strip.parseInt
    let bw = rtx_pkts - self.rtx_pkts
    self.rtx_pkts = rtx_pkts
    let perc =
      if bw >= self.max_bw:
        1.0
      else:
        1 / (1 - bw.float / self.max_bw.float) - 1
    self.full_text = self.when_found & generate_bar(perc, 3)


# RedShift

type RedShift = ref object of Module
  tick: float
  brightness: float
  temperature: float

proc newRedShift(c: JsonNode): RedShift =
  result = RedShift(name: c["name"].str, color: "", full_text: "RS")
  result.brightness = 0.7
  result.temperature = 5000
  result.tick = 0.025

method update(self: RedShift) =
  discard

proc set_screen(self: RedShift) =
  ## Update screen brightness and temperature
  process_pool.add startProcess(redshift_binpath, ".", ["-O", $self.temperature.int, "-b", $self.brightness])

method process_input(self: RedShift, event: JsonNode) =
  ## Update brightness and temperature on mouse click / wheel movement

  case event.button
  of MouseButton.WheelUp:
    self.brightness *= 1 + self.tick
    if self.brightness > 1.0:
      self.brightness = 1.0
  of MouseButton.WheelDown:
    self.brightness *= 1 - self.tick
  of MouseButton.Left:
    self.temperature *= 1 + self.tick
  of MouseButton.Right:
    self.temperature *= 1 - self.tick
  else:
    return

  info("bri: $# temp: $#" % [$self.brightness, $self.temperature])
  self.set_screen()


proc newModule(c: JsonNode): Module =
  case c["type"].str:
  of "Battery": return newBattery(c)
  of "CPU": return newCPU(c)
  of "Clock": return newClock(c)
  of "FreeDiskSpace": return newFreeDiskSpace(c)
  of "Memory": return newMemory()
  of "Network": return newNetwork()
  of "NetworkTraffic": return newNetworkTraffic(c)
  of "PlayerControl": return newPlayerControl(c)
  of "Pomodoro": return newPomodoro(c)
  of "RedShift": return newRedShift(c)
  of "Swap": return newSwap(c)
  of "Temperature": return newTemperature(c)
  else:
    echo "Unexpected module type: $#" % c["type"].str
    quit()


when isMainModule:
  let argv = commandLineParams()
  if argv.len != 1:
    echo "Please supply a config file name."
    quit(1)

  let conf: JsonNode =
    try:
      parseFile(argv[0])
    except:
      echo "Unable to parse config file: ", getCurrentExceptionMsg()
      quit(1)
      nil


  info("starting")
  echo("""{"click_events": true, "version": 1}""")
  echo("[[]")
  var modules: seq[Module] = @[]
  for modconf in conf:
    modules.add newModule(modconf)

  var skipped_initial_brace = false
  while true:
    var inp = stdin.readLine(timeout=1000)
    if inp == "":
      # Run update on every module every second
      try:
        remove_zombie_processes()
      except:
        error getCurrentExceptionMsg()
      for m in modules:
        m.update()

    else:
      # Delivery input to the right module
      if inp == "[" and skipped_initial_brace == false:
        debug("ignoring input: '$#'" % inp)
        skipped_initial_brace = true
        continue

      if inp[0] == ',':
        inp = inp[1..<inp.len]

      try:
        let j = parseJson(inp)
        if j.hasKey("name"):
          let name = j["name"].str
          for m in modules:
            if name == m.name:
              m.process_input(j)
              m.update()
              break

      except:
        error("unexpected input: '$#'" % inp)
        error getCurrentExceptionMsg()

    let qq = modules.mapit(it.gen_out_line())
    let outline = ", [$#]" % qq.join(", ")
    echo(out_line)
    flushFile(stdout)

  quit()


-- media
--
-- Loop on a medium of choice,
-- quantized or freeform.

engine.name = "Media"

local initing = true

local cabinet        = include("lib/cabinet")
local sync           = include("lib/sync")
local sprites_looper = include("lib/sprites_looper")
local looper         = include("lib/looper")
local looper_params  = include("lib/looper_params")
local looper_ui      = include("lib/looper_ui")
local lfo            = include("lib/lfo")
local env            = include("lib/env")
local trigs          = include("lib/trigger")

local B = { DIM=0, MED=5, FULL=15 }

local LOOPER_DEF = {
  { id="looper_medium",     name="Medium",     default=4,   min=1,  max=6,  step=1,   db=false, cat="Looper", options={"BBD","Cassette","CD","Chip","Tape","Vinyl"} },
  { id="looper_wear",       name="Wear",       default=5,   min=0,  max=100, step=1, db=false, unit="%", cat="Looper"  },
  { id="looper_direction",  name="Direction",  default=0,   min=0,   max=3,  step=1,  db=false, cat="Looper"  },
  { id="looper_dub_level",  name="Rec Level",  default=-2.5, min=-40, max=0, step=0.5, db=true, cat="Looper"  },
  { id="looper_level",      name="Play Level", default=-2.5, min=-40, max=0, step=0.5, db=true, cat="Looper"  },
  { id="looper_fade_level", name="Fade Level", default=-2.5, min=-40, max=0, step=0.5, db=true, cat="Looper"  },
  { id="looper_speed",      name="Speed",      default=0,   min=-100, max=100, step=1, db=false, cat="Looper"  },
  { id="looper_quant_div",  name="Quantize",      default=1,   min=1, max=8, step=1, db=false, cat="Looper", options={"Off","1/1","1/2","1/4","1/8","1/16","1/32","1/64"} },
  { id="looper_quant_feel", name="Quantize Feel", default=1,   min=1, max=3, step=1, db=false, cat="Looper", options={"Note","Dotted","Triplet"} },
}
local DIR_NAMES = looper_params.DIR_NAMES

local clock_running = true
local k_clock = {}

local db_to_lin = function(db) return 10 ^ (db / 20) end

-- ── Trigger targets (media subset) ───────────────────────────
-- IIFE keeps the loop counter out of the main chunk (L42 200-local limit).
local TRIG_TARGETS = (function()
  local t = {
    { label = "Off" },
    { label = "Looper: Rec",   id = "trig_looper_rec",   action = function() looper.step() end },
    { label = "Looper: Clear", id = "trig_looper_clear", action = function() looper.force_clear() end },
  }
  for i = 1, lfo.NUM do
    t[#t + 1] = { label = "LFO " .. i .. ": Randomize", id = "trig_lfo" .. i .. "_randomize", lfo_idx = i,
                  action = function() params:set("lfo" .. i .. "_randomize", 1) end }
  end
  return t
end)()

-- ── Mod targets (LFO) ────────────────────────────────────────
-- media-specific subset: looper continuous + looper sync + LFO self-targets.
local TARGET_PARAMS = {
  {label="Off"},
  {label="Looper: Rec Level",  id="looper_dub_level",  mn=-40,  mx=0,     st=0.5,  send=function(v) engine.looper_dub_level(db_to_lin(v)) end},
  {label="Looper: Play Level", id="looper_level",      mn=-40,  mx=0,     st=0.5,  send=function(v) engine.looper_level(db_to_lin(v)) end},
  {label="Looper: Fade Level", id="looper_fade_level", mn=-40,  mx=0,     st=0.5,  send=function(v) engine.looper_fade_level(db_to_lin(v)) end},
  {label="Looper: Speed",      id="looper_speed",      mn=-100, mx=100,   st=1,    send=function(v)
    local ratio
    if params:get("looper_speed_control") == 1 then
      if v < 0 then ratio = 0.5 elseif v > 0 then ratio = 2.0 else ratio = 1.0 end
    else ratio = 2^(v/100) end
    engine.looper_speed(ratio)
  end},
  {label="Looper: Imprint",    id="looper_imprint",    mn=0,    mx=100,   st=1,    send=function(v) engine.looper_imprint(math.floor(v)) end},
  {label="Looper: Wear",       id="looper_wear",       mn=0,    mx=100,   st=1,    send=function(v) engine.looper_wear(math.floor(v)) end},
  {label="Looper: Cassette Wow", id="looper_wow_cas",    mn=0,    mx=100,   st=1,    send=function(v) engine.looper_wow_cas(math.floor(v)) end},
  {label="Looper: CD Errors",  id="looper_cd_errors",  mn=0,    mx=100,   st=1,    send=function(v) engine.looper_cd_errors(math.floor(v)) end},
  {label="Looper: Chip Crush", id="looper_chip_crush", mn=0,    mx=100,   st=1,    send=function(v) engine.looper_chip_crush(math.floor(v)) end},
  {label="Looper: Tape Wow",   id="looper_wow_tape",   mn=0,    mx=100,   st=1,    send=function(v) engine.looper_wow_tape(math.floor(v)) end},
  {label="Looper: Quantize",   id="looper_quant_div",  mn=2,    mx=8,     st=1,    send=function(v)
    local new_v = math.floor(v+0.5)
    if lfo.sync_override["looper_quant_div"] ~= new_v then
      lfo.sync_override["looper_quant_div"] = new_v
      looper.quant_led_restart()
    end
  end},
  {label="Looper: Quantize Feel", id="looper_quant_feel", mn=1,    mx=3,     st=1,    send=function(v)
    local new_v = math.floor(v+0.5)
    if lfo.sync_override["looper_quant_feel"] ~= new_v then
      lfo.sync_override["looper_quant_feel"] = new_v
      looper.quant_led_restart()
    end
  end},
}

for i = 1, lfo.NUM do
  TARGET_PARAMS[#TARGET_PARAMS+1] = {label="LFO "..i..": Rate",  id="lfo"..i.."_rate",  mn=0.1, mx=25,  st=0.1, send=function(v) lfo.mod.rate[i]  = v end}
  TARGET_PARAMS[#TARGET_PARAMS+1] = {label="LFO "..i..": Depth", id="lfo"..i.."_depth", mn=0,   mx=100, st=1,   send=function(v) lfo.mod.depth[i] = v end}
end

for i = 1, lfo.NUM do
  TARGET_PARAMS[#TARGET_PARAMS+1] = {label="LFO "..i..": Phase",     id="lfo"..i.."_phase",     mn=1, mx=4,   st=1,   send=function(v) lfo.mod.phase[i]     = math.floor(v + 0.5) end}
  TARGET_PARAMS[#TARGET_PARAMS+1] = {label="LFO "..i..": Steps",     id="lfo"..i.."_steps",     mn=1, mx=16,  st=1,   send=function(v) lfo.mod.steps[i]     = math.floor(v + 0.5) end}
  TARGET_PARAMS[#TARGET_PARAMS+1] = {label="LFO "..i..": Stability", id="lfo"..i.."_stability", mn=0, mx=100, st=1,   send=function(v) lfo.mod.stability[i] = v end}
  TARGET_PARAMS[#TARGET_PARAMS+1] = {label="LFO "..i..": Rate Slew", id="lfo"..i.."_rate_slew", mn=0, mx=5,   st=0.1, send=function(v) lfo.mod.rate_slew[i] = v end}
  TARGET_PARAMS[#TARGET_PARAMS+1] = {label="LFO "..i..": Sync Div",  id="lfo"..i.."_sync_div",  mn=2, mx=8,   st=1,   send=function(v) lfo.mod.sync_div[i]  = math.floor(v + 0.5) end}
  TARGET_PARAMS[#TARGET_PARAMS+1] = {label="LFO "..i..": Sync Feel", id="lfo"..i.."_sync_feel", mn=1, mx=3,   st=1,   send=function(v) lfo.mod.sync_feel[i] = math.floor(v + 0.5) end}
end

for i = 1, trigs.N do
  TARGET_PARAMS[#TARGET_PARAMS+1] = {label="Trigger "..i..": Rate",        id="trig"..i.."_rate",        mn=0.1, mx=25,  st=0.1, send=function(v) trigs.mod.rate[i]        = v end}
  TARGET_PARAMS[#TARGET_PARAMS+1] = {label="Trigger "..i..": Probability", id="trig"..i.."_probability", mn=0,   mx=100, st=1,   send=function(v) trigs.mod.probability[i] = v end}
end

local DEVICE_NAMES     = {}
local DEVICE_PARAMS    = {}
local TARGET_DEVICE_OF = {}
for i = 2, #TARGET_PARAMS do
  local t = TARGET_PARAMS[i]
  if t.id then
    local dev_name, short_name = t.label:match("^(.-): (.+)$")
    if dev_name then
      local di
      for ix, dn in ipairs(DEVICE_NAMES) do
        if dn == dev_name then di = ix; break end
      end
      if not di then
        DEVICE_NAMES[#DEVICE_NAMES + 1] = dev_name
        di = #DEVICE_NAMES
        DEVICE_PARAMS[di] = {}
      end
      DEVICE_PARAMS[di][#DEVICE_PARAMS[di] + 1] = { global_idx = i, short = short_name }
      TARGET_DEVICE_OF[i] = di
    end
  end
end

-- ── Mod-rack view state (file scope; populated in init) ──────
local view           = 0   -- 0 = looper pane, 1 = mod rack
local rack_pane      = 1
local RACK           = {}   -- data-driven source list: {kind=..., idx=...}
local rack_strip_sel = {}   -- per-source strip selection (keyed for lfo by lfo idx)

-- ── Value formatting ─────────────────────────────────────────
local function fmt_unit(v, p)
  if p.unit then
    return p.step < 1 and string.format("%.1f%s", v, p.unit) or string.format("%d%s", math.floor(v), p.unit)
  end
  return string.format("%.1f", v)
end

local function fmt_def_val(def, idx)
  local p  = def[idx]
  local id = p.id
  local v  = params:get(id)
  if p.options then return p.options[v] end
  if id == "looper_direction" then return DIR_NAMES[v] end
  if id == "looper_speed" then
    if params:get("looper_speed_control") == 1 then
      if v < 0 then return "-100%" elseif v > 0 then return "+100%" else return "+0%" end
    else
      return string.format("%+d%%", math.floor(v))
    end
  end
  local s = sync.fmt(id, clock_running)
  if s then return s end
  if p.db   then return string.format("%.1fdB", v) end
  return fmt_unit(v, p)
end

local function snap_val(v, step)
  if step == 1 then return math.floor(v + 0.5)
  else return math.floor(v * 10 + 0.5) / 10 end
end

-- one editing path for the looper pane, mirroring princeton's edit_param;
-- no looper param uses sync.PARAM_MAP, so the sync-division redirect is omitted.
local PARAM_STEP = {}
for _, e in ipairs(LOOPER_DEF) do PARAM_STEP[e.id] = e.step end

local function edit_param(id, d)
  local step = PARAM_STEP[id]
  if step then
    params:set(id, snap_val(params:get(id) + d * step, step))
  else
    params:delta(id, d)
  end
end

-- ── Transport icons + left strip ─────────────────────────────
local function draw_icon_filled_circle(cx, y)
  screen.rect(cx - 5, y - 2, 10, 4)
  screen.rect(cx - 2, y - 5, 4, 10)
  screen.rect(cx - 4, y - 4, 2, 2)
  screen.rect(cx + 2, y - 4, 2, 2)
  screen.rect(cx - 4, y + 2, 2, 2)
  screen.rect(cx + 2, y + 2, 2, 2)
  screen.fill()
end

local function draw_icon_record(cx, y, lv)
  screen.level(lv)
  draw_icon_filled_circle(cx, y)
end

local function draw_icon_dub(cx, y, lv)
  screen.level(lv)
  draw_icon_filled_circle(cx, y)
  screen.line_width(1)
  local px, py = cx + 8, y - 3
  screen.move(px-2, py); screen.line(px+1, py); screen.stroke()
  screen.move(px, py-2); screen.line(px, py+1); screen.stroke()
end

local function draw_icon_play(cx, y, lv)
  screen.level(lv)
  screen.move(cx-4, y-5); screen.line(cx+5, y); screen.line(cx-4, y+5)
  screen.fill()
end

local function draw_icon_stop(cx, y, lv)
  screen.level(lv); screen.rect(cx-4, y-4, 8, 8); screen.fill()
end

local function draw_strip(cat, name, val_str, val_lv, val_str2)
  val_lv = val_lv or B.FULL
  screen.level(B.DIM); screen.rect(0, 0, cabinet.LEFT_W, 64); screen.fill()
  screen.font_size(8); screen.font_face(0)
  screen.level(B.MED);  screen.move(cabinet.LEFT_CX,  8); screen.text_center(cat)
  local name2
  local sp = name:find(" ")
  if sp then name, name2 = name:sub(1, sp - 1), name:sub(sp + 1) end
  local vy = 26
  screen.level(B.MED); screen.move(cabinet.LEFT_CX, 17); screen.text_center(name)
  if name2 then
    screen.level(B.MED); screen.move(cabinet.LEFT_CX, 26); screen.text_center(name2)
    vy = 35
  end
  if val_str then
    val_str = val_str:gsub("(%-?%d+)%.%d+(%s*%%)", "%1%2")
    val_str = val_str:gsub("(%d)%s+([%a%%])", "%1%2")
  end
  screen.level(val_lv); screen.move(cabinet.LEFT_CX, vy); screen.text_center(val_str)
  if val_str2 then
    screen.level(val_lv); screen.move(cabinet.LEFT_CX, vy + 9); screen.text_center(val_str2)
  end
end

local function draw_looper_state_icon()
  if     looper.state == looper.REC  then draw_icon_record(cabinet.LEFT_CX, cabinet.ICON_Y, B.FULL)
  elseif looper.state == looper.DUB  then draw_icon_dub(cabinet.LEFT_CX, cabinet.ICON_Y, B.FULL)
  elseif looper.state == looper.PLAY then draw_icon_play(cabinet.LEFT_CX, cabinet.ICON_Y, B.FULL)
  elseif looper.state == looper.STOP then draw_icon_stop(cabinet.LEFT_CX, cabinet.ICON_Y, B.MED)
  end
end

-- ── Key hold ─────────────────────────────────────────────────
local function long_press(key_id, z, fn_long, fn_short)
  if z == 1 then
    k_clock[key_id] = clock.run(function()
      clock.sleep(2.0)
      k_clock[key_id] = nil
      fn_long()
    end)
  else
    if k_clock[key_id] ~= nil then
      clock.cancel(k_clock[key_id])
      k_clock[key_id] = nil
      if fn_short then fn_short() end
    end
  end
end

-- ── Clock tracking (global Norns clock) ──────────────────────
local function setup_clock_watchers()
  clock.transport.start = function()
    clock_running = true
    looper.quant_led_restart()
    redraw()
  end
  clock.transport.stop = function()
    clock_running = false
    looper.quant_led_restart()
    redraw()
  end
  clock.run(function()
    local last_bpm = 0
    while true do
      clock.sleep(0.5)
      local bpm = math.floor(clock.get_tempo() + 0.5)
      if bpm ~= last_bpm then
        if last_bpm == 0 and bpm > 0 then
          clock_running = true
          looper.quant_led_restart()
        elseif bpm == 0 and last_bpm > 0 then
          clock_running = false
          looper.quant_led_restart()
        end
        last_bpm = bpm
        redraw()
      end
    end
  end)
end

-- ── Mod-rack pane ────────────────────────────────────────────
local function draw_label_cursor(cx, baseline, text)
  screen.font_size(8); screen.font_face(0)
  local w = screen.text_extents(text)
  local left_x = cx - math.floor(w / 2)
  screen.level(B.FULL)
  screen.rect(left_x - 2, baseline - 5, 1, 1); screen.fill()
end

local function draw_rack_pane()
  screen.clear()
  local p       = rack_pane
  local pair    = math.ceil(p / 2)
  local is_left = (p % 2) == 1
  local OX1     = cabinet.CAB.x
  local OX2     = cabinet.CAB.x + cabinet.CAB.w - 33
  local py      = 4

  local src_l = RACK[2 * pair - 1]
  local src_r = RACK[2 * pair]
  local src   = RACK[p]

  -- dispatch on source kind so env/trig can be added in later stages
  if src.kind == "lfo" then
    local lfo_l = src_l and src_l.idx
    local lfo_r = src_r and src_r.idx
    if lfo_l then lfo.draw_half(OX1, py, lfo_l, is_left) end
    if lfo_r then lfo.draw_half(OX2, py, lfo_r, not is_left) end

    local idx       = src.idx
    local strip_idx = lfo.strip_resolve(idx, rack_strip_sel[idx] or 1)
    local ls        = lfo.STRIP[strip_idx]
    local id        = "lfo" .. idx .. ls.suf
    local v1        = ls.fmt(params:get(id), idx)
    local v2        = nil
    if ls.suf == "_waveform" or ls.suf == "_target_param" then
      local sp = v1:find(" ")
      if sp then v1, v2 = v1:sub(1, sp - 1), v1:sub(sp + 1) end
    end
    draw_strip("LFO " .. idx, ls.name, v1, B.FULL, v2)
  elseif src.kind == "env" then
    local env_l = src_l and src_l.idx
    local env_r = src_r and src_r.idx
    if env_l then env.draw_half(OX1, py, env_l, is_left) end
    if env_r then env.draw_half(OX2, py, env_r, not is_left) end

    local idx = src.idx
    local es  = env.STRIP[env.strip_sel[idx] or 1]
    local id  = "env" .. idx .. es.suf
    local v1  = es.fmt(params:get(id), idx)
    local v2  = nil
    if es.suf == "_target_param" then
      local sp = v1:find(" ")
      if sp then v1, v2 = v1:sub(1, sp - 1), v1:sub(sp + 1) end
    end
    draw_strip("Sense " .. idx, es.name, v1, B.FULL, v2)
  elseif src.kind == "trig" then
    local trig_l = src_l and src_l.idx
    local trig_r = src_r and src_r.idx
    if trig_l then trigs.draw_half(OX1, py, trig_l, is_left) end
    if trig_r then trigs.draw_half(OX2, py, trig_r, not is_left) end

    local idx       = src.idx
    local strip_idx = trigs.strip_fn.resolve(idx, trigs.strip_sel[idx] or 1)
    local ts        = trigs.STRIP[strip_idx]
    local id        = "trig" .. idx .. ts.suf
    local v1        = ts.fmt(params:get(id), idx)
    draw_strip("Trigger " .. idx, ts.name, v1, B.FULL)
  end

  local cur_cx = (is_left and OX1 or OX2) + 16
  local cur_label
  if     src.kind == "env"  then cur_label = "Sense " .. src.idx
  elseif src.kind == "trig" then cur_label = "Trig "  .. src.idx
  else                           cur_label = "LFO "   .. src.idx end
  draw_label_cursor(cur_cx, py + 56, cur_label)
  screen.update()
end

-- ── Norns callbacks ──────────────────────────────────────────
function redraw()
  if view == 1 then draw_rack_pane() else looper_ui.draw_pane() end
end

function enc(n, d)
  if view == 1 then
    if n == 1 then
      rack_pane = util.clamp(rack_pane + d, 1, #RACK)
      redraw()
      return
    end
    local src = RACK[rack_pane]
    if src.kind == "lfo" then
      local idx = src.idx
      if n == 2 then
        rack_strip_sel[idx] = lfo.strip_advance(idx, rack_strip_sel[idx] or 1, d)
        redraw()
      elseif n == 3 then
        local strip_idx = lfo.strip_resolve(idx, rack_strip_sel[idx] or 1)
        local ls = lfo.STRIP[strip_idx]
        local id = "lfo" .. idx .. ls.suf
        if ls.typ == "opt" then
          local nmax = ls.nmax_fn and ls.nmax_fn(idx) or ls.nmax
          if nmax > 0 then
            params:set(id, util.clamp(params:get(id) + d, 1, nmax))
          end
        else
          params:set(id, snap_val(params:get(id) + d * ls.step, ls.step))
        end
        if ls.suf == "_sync_div" then lfo.start_clock(idx) end
        redraw()
      end
    elseif src.kind == "env" then
      local idx = src.idx
      if n == 2 then
        env.strip_sel[idx] = env.strip_advance(idx, env.strip_sel[idx] or 1, d)
        redraw()
      elseif n == 3 then
        local es = env.STRIP[env.strip_sel[idx] or 1]
        local id = "env" .. idx .. es.suf
        if es.typ == "opt" then
          local nmax = es.nmax_fn and es.nmax_fn(idx) or es.nmax
          if nmax > 0 then
            params:set(id, util.clamp(params:get(id) + d, 1, nmax))
          end
        else
          params:set(id, snap_val(params:get(id) + d * es.step, es.step))
        end
        redraw()
      end
    elseif src.kind == "trig" then
      local idx = src.idx
      if n == 2 then
        trigs.strip_sel[idx] = trigs.strip_fn.advance(idx, trigs.strip_sel[idx] or 1, d)
        redraw()
      elseif n == 3 then
        local strip_idx = trigs.strip_fn.resolve(idx, trigs.strip_sel[idx] or 1)
        local ts = trigs.STRIP[strip_idx]
        local id = "trig" .. idx .. ts.suf
        if ts.typ == "opt" then
          local nmax = ts.nmax_fn and ts.nmax_fn(idx) or ts.nmax
          if nmax > 0 then
            params:set(id, util.clamp(params:get(id) + d, 1, nmax))
          end
        else
          params:set(id, snap_val(params:get(id) + d * ts.step, ts.step))
        end
        if ts.suf == "_sync_div" then trigs.fn.start_clock(idx) end
        redraw()
      end
    end
    return
  end
  looper_ui.enc(n, d)
end

function key(n, z)
  if n == 1 then
    long_press("k1", z, function() view = 1 - view; redraw() end)
  elseif n == 2 then
    long_press("k2", z, function() end, function()
      if view == 1 then
        local src = RACK[rack_pane]
        if src.kind == "lfo" then params:set("lfo" .. src.idx .. "_randomize", 1) end
      else
        looper.stop_clear()
      end
    end)
  elseif n == 3 then
    long_press("k3", z, function() end, function()
      if view == 1 then
        local src = RACK[rack_pane]
        if src.kind == "lfo" then
          local cur = params:get("lfo" .. src.idx .. "_enable")
          params:set("lfo" .. src.idx .. "_enable", 3 - cur)
        elseif src.kind == "env" then
          local cur = params:get("env" .. src.idx .. "_enable")
          params:set("env" .. src.idx .. "_enable", 3 - cur)
        elseif src.kind == "trig" then
          local cur = params:get("trig" .. src.idx .. "_enable")
          params:set("trig" .. src.idx .. "_enable", 3 - cur)
        end
      else
        looper.step()
      end
    end)
  end
end

function init()
  local function re() if not initing then redraw() end end

  -- ── LFO target dropdown helpers (init-local; mirror princeton) ──
  local function find_filtered_idx(map, target)
    if map then
      for fi, gi in ipairs(map) do
        if gi == target then return fi end
      end
    end
    return 1
  end

  local function ui_revert(param_id, target_idx)
    local p = params:lookup_param(param_id)
    if p and p.selected ~= target_idx then
      p.selected = target_idx
      if _menu and _menu.rebuild_params then _menu.rebuild_params() end
    end
  end

  local function register_lfo(idx)
    local prefix = "lfo" .. idx

    local function refresh_visibility()
      local wf  = params:get(prefix .. "_waveform")
      local div = params:get(prefix .. "_sync_div")
      if div > 1 then
        params:hide(prefix .. "_rate")
      else
        params:show(prefix .. "_rate")
      end
      if wf == 6 then
        params:hide(prefix .. "_phase")
        params:hide(prefix .. "_rate_slew")
        params:show(prefix .. "_steps"); params:show(prefix .. "_stability")
        params:show(prefix .. "_sep_trigger"); params:show(prefix .. "_randomize")
      else
        params:show(prefix .. "_phase")
        params:show(prefix .. "_rate_slew")
        params:hide(prefix .. "_steps"); params:hide(prefix .. "_stability")
        params:hide(prefix .. "_sep_trigger"); params:hide(prefix .. "_randomize")
      end
      if _menu and _menu.rebuild_params then _menu.rebuild_params() end
    end

    local function compute_intended_global()
      local dev_filtered = params:get(prefix .. "_target_device")
      local dev_idx = (lfo.target_device_filter[idx] and lfo.target_device_filter[idx][dev_filtered]) or 1
      local param_filtered = params:get(prefix .. "_target_param")
      local g = (lfo.target_param_filter[idx] and lfo.target_param_filter[idx][param_filtered]) or 1
      if g <= 1 and DEVICE_PARAMS[dev_idx] and DEVICE_PARAMS[dev_idx][1] then
        g = DEVICE_PARAMS[dev_idx][1].global_idx
      end
      return g
    end

    params:add_group("MOD LFO " .. idx, 18)
    params:add_separator(prefix .. "_sep_control", "─── Control ───")

    params:add_option(prefix .. "_enable", "Enable", {"Off", "On"}, 1)
    params:set_action(prefix .. "_enable", function(v)
      if not initing then
        if v == 2 then
          local g = compute_intended_global()
          local own = g > 1 and lfo.target_owner[TARGET_PARAMS[g].id]
          if own and own ~= idx then
            for i = 2, #TARGET_PARAMS do
              if not lfo.target_owner[TARGET_PARAMS[i].id] then g = i; break end
            end
          end
          lfo.set_target(idx, g)
        else
          lfo.set_target(idx, lfo.last_global[idx] or 1)
        end
      end
      re()
    end)

    params:add_option(prefix .. "_waveform", "Waveform", lfo.WAVEFORMS, 1)
    params:set_action(prefix .. "_waveform", function(_)
      refresh_visibility()
      if not initing then
        lfo.start_clock(idx)
        lfo.refresh_dropdowns_for_device("LFO " .. idx)
        trigs.fn.refresh_dropdowns_for_lfo(idx)
      end
      re()
    end)

    params:add_control(prefix .. "_rate", "Rate", controlspec.new(0.1, 25, "exp", 0.1, 1.0, "Hz"))
    params:set_action(prefix .. "_rate", function(_)
      lfo.mod.rate[idx] = nil
      lfo.target_base[prefix .. "_rate"] = nil
    end)

    params:add_control(prefix .. "_depth", "Depth", controlspec.new(0, 100, "lin", 1, 50, "%"))
    params:set_action(prefix .. "_depth", function(_)
      lfo.mod.depth[idx] = nil
      lfo.target_base[prefix .. "_depth"] = nil
    end)

    params:add_option(prefix .. "_dir", "Direction", lfo.DIR_OPTS, 3)

    params:add_option(prefix .. "_phase", "Phase", {"0°", "90°", "180°", "270°"}, 1)
    params:set_action(prefix .. "_phase", function(_)
      lfo.mod.phase[idx] = nil
      lfo.target_base[prefix .. "_phase"] = nil
    end)

    params:add_number(prefix .. "_steps", "Steps", 1, 16, 8)
    params:set_action(prefix .. "_steps", function(v)
      lfo.mod.steps[idx] = nil
      lfo.target_base[prefix .. "_steps"] = nil
      local s = lfo.state[idx]
      if s then s.tm_register = s.tm_register & lfo.tm_register_max(v) end
    end)

    params:add_control(prefix .. "_stability", "Stability", controlspec.new(0, 100, "lin", 1, 50, "%"))
    params:set_action(prefix .. "_stability", function(_)
      lfo.mod.stability[idx] = nil
      lfo.target_base[prefix .. "_stability"] = nil
    end)

    params:add_control(prefix .. "_rate_slew", "Rate Slew", controlspec.new(0, 5, "lin", 0.1, 0, "s"))
    params:set_action(prefix .. "_rate_slew", function(_)
      lfo.mod.rate_slew[idx] = nil
      lfo.target_base[prefix .. "_rate_slew"] = nil
    end)

    params:add_separator(prefix .. "_sep_sync", "─── Synchronization ───")

    params:add_option(prefix .. "_sync_div", "Sync", sync.DIV_OPTS, 1)
    params:set_action(prefix .. "_sync_div", function(_)
      lfo.mod.sync_div[idx] = nil
      lfo.target_base[prefix .. "_sync_div"] = nil
      refresh_visibility()
      if not initing then
        lfo.refresh_dropdowns_for_device("LFO " .. idx)
        lfo.start_clock(idx)
      end
    end)

    params:add_option(prefix .. "_sync_feel", "Sync Feel", sync.FEEL_OPTS, 1)
    params:set_action(prefix .. "_sync_feel", function(_)
      lfo.mod.sync_feel[idx] = nil
      lfo.target_base[prefix .. "_sync_feel"] = nil
    end)

    params:add_separator(prefix .. "_sep_target", "─── Target ───")

    params:add_option(prefix .. "_target_device", "Target Device", {"-"}, 1)
    params:set_action(prefix .. "_target_device", function(filtered_v)
      if not initing then
        local cur_global = lfo.last_global[idx] or 1
        local cur_dev = TARGET_DEVICE_OF[cur_global] or 0
        local dmap = lfo.target_device_filter[idx]
        local cur_filtered = find_filtered_idx(dmap, cur_dev)
        if not params.pset_loading then
          if filtered_v > cur_filtered + 1 then filtered_v = cur_filtered + 1
          elseif filtered_v < cur_filtered - 1 then filtered_v = cur_filtered - 1 end
        end
        local new_dev = (dmap and dmap[filtered_v]) or 1
        if new_dev ~= cur_dev or params.pset_loading then
          lfo.rebuild_target_param_dropdown(idx, new_dev)
          local new_global = 1
          if DEVICE_PARAMS[new_dev] then
            for _, entry in ipairs(DEVICE_PARAMS[new_dev]) do
              local owner = lfo.target_owner[TARGET_PARAMS[entry.global_idx].id]
              if owner == nil or owner == idx then new_global = entry.global_idx; break end
            end
          end
          lfo.set_target(idx, new_global)
        else
          ui_revert(prefix .. "_target_device", cur_filtered)
        end
      end
      re()
    end)

    params:add_option(prefix .. "_target_param", "Target Param", {"-"}, 1)
    params:set_action(prefix .. "_target_param", function(filtered_v)
      if not initing then
        local cur_global = lfo.last_global[idx] or 1
        local pmap = lfo.target_param_filter[idx]
        local cur_filtered = find_filtered_idx(pmap, cur_global)
        if not params.pset_loading then
          if filtered_v > cur_filtered + 1 then filtered_v = cur_filtered + 1
          elseif filtered_v < cur_filtered - 1 then filtered_v = cur_filtered - 1 end
        end
        local new_global = (pmap and pmap[filtered_v]) or 1
        if new_global ~= cur_global then
          lfo.set_target(idx, new_global)
        else
          ui_revert(prefix .. "_target_param", cur_filtered)
        end
      end
      re()
    end)

    params:add_separator(prefix .. "_sep_trigger", "─── Trigger ───")

    params:add_binary(prefix .. "_randomize", "Randomize", "trigger", 0)
    params:set_action(prefix .. "_randomize", function(v)
      if v == 1 and not initing then lfo.tm_randomize(idx) end
    end)
  end

  local function register_trigger(idx)
    local prefix = "trig" .. idx

    local function refresh_visibility()
      local div = params:get(prefix .. "_sync_div")
      if div > 1 then params:hide(prefix .. "_rate")
      else            params:show(prefix .. "_rate") end
      if _menu and _menu.rebuild_params then _menu.rebuild_params() end
    end

    local default_dev = 1
    local dev_shorts = {}
    if trigs.DEVICE_PARAMS[default_dev] then
      for _, e in ipairs(trigs.DEVICE_PARAMS[default_dev]) do
        dev_shorts[#dev_shorts + 1] = e.label
      end
    end
    if #dev_shorts == 0 then dev_shorts = {"-"} end

    params:add_group("MOD TRIGGER " .. idx, 10)
    params:add_separator(prefix .. "_sep_control", "─── Control ───")

    params:add_option(prefix .. "_enable", "Enable", {"Off", "On"}, 1)
    params:set_action(prefix .. "_enable", function(_)
      if not initing then trigs.fn.set_enable(idx) end
      re()
    end)

    params:add_control(prefix .. "_probability", "Probability", controlspec.new(0, 100, "lin", 1, 100, "%"))
    params:set_action(prefix .. "_probability", function(_)
      trigs.mod.probability[idx] = nil
      lfo.target_base[prefix .. "_probability"] = nil
      re()
    end)

    params:add_control(prefix .. "_rate", "Rate", controlspec.new(0.1, 25, "exp", 0.1, 1.0, "Hz"))
    params:set_action(prefix .. "_rate", function(_)
      trigs.mod.rate[idx] = nil
      lfo.target_base[prefix .. "_rate"] = nil
    end)

    params:add_separator(prefix .. "_sep_sync", "─── Synchronization ───")

    params:add_option(prefix .. "_sync_div", "Sync", sync.DIV_OPTS, 1)
    params:set_action(prefix .. "_sync_div", function(_)
      refresh_visibility()
      if not initing then trigs.fn.start_clock(idx) end
      re()
    end)

    params:add_option(prefix .. "_sync_feel", "Sync Feel", sync.FEEL_OPTS, 1)

    params:add_separator(prefix .. "_sep_target", "─── Target ───")

    params:add_option(prefix .. "_target_device", "Device", trigs.DEVICES, default_dev)
    params:set_action(prefix .. "_target_device", function(filtered_v)
      if not initing then
        local cur_global = trigs.last_global[idx] or 1
        local cur_dev = trigs.TARGET_DEVICE_OF[cur_global]
        if not cur_dev then
          local dev_filtered = params:get(prefix .. "_target_device")
          cur_dev = (trigs.target_device_filter[idx] and trigs.target_device_filter[idx][dev_filtered]) or 1
        end
        local dmap = trigs.target_device_filter[idx]
        local cur_filtered = find_filtered_idx(dmap, cur_dev)
        if not params.pset_loading then
          if filtered_v > cur_filtered + 1 then filtered_v = cur_filtered + 1
          elseif filtered_v < cur_filtered - 1 then filtered_v = cur_filtered - 1 end
        end
        local new_dev = (dmap and dmap[filtered_v]) or 1
        if new_dev ~= cur_dev or params.pset_loading then
          trigs.fn.rebuild_target_param_dropdown(idx, new_dev)
          local new_global = 1
          if trigs.DEVICE_PARAMS[new_dev] then
            for _, entry in ipairs(trigs.DEVICE_PARAMS[new_dev]) do
              local tid = trigs.TARGETS[entry.global_idx].id
              local owner = tid and trigs.target_owner[tid]
              if owner == nil or owner == idx then new_global = entry.global_idx; break end
            end
          end
          trigs.fn.set_target(idx, new_global)
        else
          ui_revert(prefix .. "_target_device", cur_filtered)
        end
      end
      re()
    end)

    params:add_option(prefix .. "_target_param", "Target", dev_shorts, 1)
    params:set_action(prefix .. "_target_param", function(filtered_v)
      if not initing then
        local cur_global = trigs.last_global[idx] or 1
        local pmap = trigs.target_param_filter[idx]
        local cur_filtered = find_filtered_idx(pmap, cur_global)
        if not params.pset_loading then
          if filtered_v > cur_filtered + 1 then filtered_v = cur_filtered + 1
          elseif filtered_v < cur_filtered - 1 then filtered_v = cur_filtered - 1 end
        end
        local new_global = (pmap and pmap[filtered_v]) or 1
        if new_global ~= cur_global then
          trigs.fn.set_target(idx, new_global)
        else
          ui_revert(prefix .. "_target_param", cur_filtered)
        end
      end
      re()
    end)
  end

  local function register_env(idx)
    local prefix = "env" .. idx

    local function compute_intended_global()
      local dev_filtered = params:get(prefix .. "_target_device")
      local dev_idx = (env.target_device_filter[idx] and env.target_device_filter[idx][dev_filtered]) or 1
      local param_filtered = params:get(prefix .. "_target_param")
      local g = (env.target_param_filter[idx] and env.target_param_filter[idx][param_filtered]) or 1
      if g <= 1 and DEVICE_PARAMS[dev_idx] and DEVICE_PARAMS[dev_idx][1] then
        g = DEVICE_PARAMS[dev_idx][1].global_idx
      end
      return g
    end

    params:add_group("MOD SENSE " .. idx, 8)
    params:add_separator(prefix .. "_sep_control", "─── Control ───")

    params:add_option(prefix .. "_enable", "Enable", {"Off", "On"}, 1)
    params:set_action(prefix .. "_enable", function(v)
      if not initing then
        if v == 2 then
          local g = compute_intended_global()
          local own = g > 1 and lfo.target_owner[TARGET_PARAMS[g].id]
          if own and own ~= "env_" .. idx then
            for i = 2, #TARGET_PARAMS do
              if not lfo.target_owner[TARGET_PARAMS[i].id] then g = i; break end
            end
          end
          env.set_target(idx, g)
        else
          env.set_target(idx, env.last_global[idx] or 1)
        end
        env.poll_set_active(idx, v == 2)
      end
      re()
    end)

    params:add_control(prefix .. "_depth", "Depth", controlspec.new(0, 100, "lin", 1, 50, "%"))

    params:add_option(prefix .. "_dir", "Direction", env.DIR_OPTS, 1)

    params:add_control(prefix .. "_slew", "Slew", controlspec.new(1, 500, "lin", 1, 50, "ms"))
    params:set_action(prefix .. "_slew", function(v)
      local s = v / 1000
      engine[prefix .. "_attack"](s)
      engine[prefix .. "_release"](s)
    end)

    params:add_separator(prefix .. "_sep_target", "─── Target ───")

    params:add_option(prefix .. "_target_device", "Target Device", {"-"}, 1)
    params:set_action(prefix .. "_target_device", function(filtered_v)
      if not initing then
        local cur_global = env.last_global[idx] or 1
        local cur_dev = TARGET_DEVICE_OF[cur_global] or 0
        local dmap = env.target_device_filter[idx]
        local cur_filtered = find_filtered_idx(dmap, cur_dev)
        if not params.pset_loading then
          if filtered_v > cur_filtered + 1 then filtered_v = cur_filtered + 1
          elseif filtered_v < cur_filtered - 1 then filtered_v = cur_filtered - 1 end
        end
        local new_dev = (dmap and dmap[filtered_v]) or 1
        if new_dev ~= cur_dev or params.pset_loading then
          env.rebuild_target_param_dropdown(idx, new_dev)
          local new_global = 1
          if DEVICE_PARAMS[new_dev] then
            for _, entry in ipairs(DEVICE_PARAMS[new_dev]) do
              local owner = lfo.target_owner[TARGET_PARAMS[entry.global_idx].id]
              if owner == nil or owner == "env_" .. idx then new_global = entry.global_idx; break end
            end
          end
          env.set_target(idx, new_global)
        else
          ui_revert(prefix .. "_target_device", cur_filtered)
        end
      end
      re()
    end)

    params:add_option(prefix .. "_target_param", "Target Param", {"-"}, 1)
    params:set_action(prefix .. "_target_param", function(filtered_v)
      if not initing then
        local cur_global = env.last_global[idx] or 1
        local pmap = env.target_param_filter[idx]
        local cur_filtered = find_filtered_idx(pmap, cur_global)
        if not params.pset_loading then
          if filtered_v > cur_filtered + 1 then filtered_v = cur_filtered + 1
          elseif filtered_v < cur_filtered - 1 then filtered_v = cur_filtered - 1 end
        end
        local new_global = (pmap and pmap[filtered_v]) or 1
        if new_global ~= cur_global then
          env.set_target(idx, new_global)
        else
          ui_revert(prefix .. "_target_param", cur_filtered)
        end
      end
      re()
    end)
  end

  looper.init({
    is_clock_running = function() return clock_running end,
    get_override     = function() return lfo.sync_override end,
    is_pane_visible  = function() return view == 0 end,
  })

  lfo.init({
    TARGET_PARAMS    = TARGET_PARAMS,
    DEVICE_NAMES     = DEVICE_NAMES,
    DEVICE_PARAMS    = DEVICE_PARAMS,
    TARGET_DEVICE_OF = TARGET_DEVICE_OF,
    is_clock_running = function() return clock_running end,
    is_initing       = function() return initing end,
    on_sync_override_change = function(target_id)
      if target_id == "looper_quant_div" or target_id == "looper_quant_feel" then
        looper.quant_led_restart()
      end
    end,
    get_trigs_mod    = function() return trigs.mod end,
    on_target_change = function() env.rebuild_all_target_dropdowns() end,
  })

  env.init({
    TARGET_PARAMS     = TARGET_PARAMS,
    DEVICE_NAMES      = DEVICE_NAMES,
    DEVICE_PARAMS     = DEVICE_PARAMS,
    TARGET_DEVICE_OF  = TARGET_DEVICE_OF,
    lfo               = lfo,
    is_initing        = function() return initing end,
    is_pane_visible_l = function() return view == 1 and rack_pane == 1 end,
    is_pane_visible_r = function() return view == 1 and rack_pane == 2 end,
    redraw_pane       = function() if not initing then redraw() end end,
  })

  trigs.init({
    looper           = looper,
    lfo              = lfo,
    targets          = TRIG_TARGETS,
    is_initing       = function() return initing end,
    is_clock_running = function() return clock_running end,
  })
  looper_ui.init({
    draw_strip      = draw_strip,
    fmt_val         = function(i) return fmt_def_val(LOOPER_DEF, i) end,
    LOOPER_DEF      = LOOPER_DEF,
    val_level       = function(id) return sync.val_level(id, clock_running) end,
    draw_state_icon = draw_looper_state_icon,
    B               = B,
    looper          = looper,
    LOOPER_PTS      = sprites_looper.LOOPER_PTS,
    edit_param      = edit_param,
  })
  params:add_separator("media_header", "─── MEDIA ───")
  params:add_group("SIGNAL FLOW", 5)
  params:add_separator("signal_flow_sep_control", "─── Control ───")
  params:add_option("fx_send_a_source", "Send A Source", {"Input", "Looper", "Output"}, 3)
  params:set_action("fx_send_a_source", function(v) engine.fx_send_a_source(v - 1) end)
  params:add_control("fx_send_a_level", "Send A Level", controlspec.new(-60, 10, "lin", 0.5, 0, "dB"))
  params:set_action("fx_send_a_level", function(v) engine.fx_send_a_level(db_to_lin(v)) end)
  params:add_option("fx_send_b_source", "Send B Source", {"Input", "Looper", "Output"}, 3)
  params:set_action("fx_send_b_source", function(v) engine.fx_send_b_source(v - 1) end)
  params:add_control("fx_send_b_level", "Send B Level", controlspec.new(-60, 10, "lin", 0.5, 0, "dB"))
  params:set_action("fx_send_b_level", function(v) engine.fx_send_b_level(db_to_lin(v)) end)

  looper_params.setup({
    re                   = re,
    db_to_lin            = db_to_lin,
    is_initing           = function() return initing end,
    on_quant_div_changed = function() lfo.refresh_dropdowns_for_device("Looper") end,
    speed_is_owned       = function() return lfo.target_owner["looper_speed"] ~= nil end,
    looper               = looper,
    embedded             = true,
  })

  -- mod rack groups, in rack order: Sense, LFO, Trigger
  for i = 1, env.NUM do register_env(i) end
  for i = 1, lfo.NUM do register_lfo(i) end
  for i = 1, trigs.N do register_trigger(i) end

  -- ── Mod-source action wrapper ──────────────────────────────
  local function target_active(id)
    local owner = lfo.target_owner[id]
    if owner == nil then return false end
    if type(owner) == "number" then return lfo.is_enabled(owner) end
    local n = type(owner) == "string" and owner:match("^env_(%d+)$")
    return n ~= nil and env.is_enabled(tonumber(n))
  end

  for _, t in ipairs(TARGET_PARAMS) do
    if t.id then
      local p = params:lookup_param(t.id)
      if p and p.action then
        local orig = p.action
        params:set_action(t.id, function(v)
          lfo.target_base[t.id] = v
          if t.id == "looper_speed" or not target_active(t.id) then orig(v) end
        end)
      end
    end
  end

  params:bang()
  initing = false

  for i = 1, lfo.NUM do lfo.set_target(i, 1) end
  for i = 1, env.NUM do env.set_target(i, 1) end
  env.start_polls()

  for i = 1, trigs.N do
    trigs.fn.set_target(i, trigs.last_global[i] or 1)
    trigs.fn.set_enable(i)
  end

  -- ── Build mod-rack source list (2 Sense, then 8 LFO, then 4 trigger) ──
  for i = 1, env.NUM do RACK[#RACK + 1] = { kind = "env", idx = i } end
  for i = 1, lfo.NUM do RACK[#RACK + 1] = { kind = "lfo", idx = i } end
  for i = 1, trigs.N do RACK[#RACK + 1] = { kind = "trig", idx = i } end

  setup_clock_watchers()
  redraw()
end

function cleanup()
  for _, c in pairs(k_clock) do if c then clock.cancel(c) end end
end

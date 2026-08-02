-- stepiii v2.0.0
pset_init("stepiii")

local grid_dirty, sys_time = true, 0
local font = {
 ["0"]="011101101101110", ["1"]="010110010010111", ["2"]="110001111100111",
 ["3"]="110001111001111", ["4"]="101101111001001", ["5"]="111100111001110",
 ["6"]="011100111101111", ["7"]="111001010010010", ["8"]="011101111101110",
 ["9"]="111101111001110", ["-"]="000000111000000", ["+"]="000010111010000",
 ["E"]="111100110100111", ["X"]="101101010101101", ["T"]="111010010010010",
 ["A"]="011101111101101", ["L"]="100100100100111", ["%"]="101001010100101"
}

local function draw_text(txt, start_x, start_y)
 local str = tostring(txt)
 for c = 1, #str do
  local pat = font[str:sub(c, c)]
  if pat then 
   for i = 1, 15 do if pat:sub(i, i) == "1" then grid_led(start_x + ((c-1)*4) + ((i-1)%3), start_y + math.floor((i-1)/3), 5) end end
  end
 end
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function adj_btns(x, y, get, set, small, big, lo, hi)
 if x == 13 then
  if y == 4 then set(clamp(get() + small, lo, hi)); return true
  elseif y == 5 then set(clamp(get() - small, lo, hi)); return true
  elseif y == 7 then set(clamp(get() + big, lo, hi)); return true
  elseif y == 8 then set(clamp(get() - big, lo, hi)); return true end
 end
 return false
end

local trks, presets, act_pset, p_held, p_blink, shft_press = {}, {}, {}, {}, {}, {}
for i, n in ipairs({49, 51, 46, 42, 38, 41, 36}) do
 trks[i] = { note=n, ch=10, steps={}, ratch={}, len=16, mute=false, swing=50, m_time=0, pos=0 }
 presets[i], act_pset[i], p_held[i], p_blink[i], shft_press[i] = {}, nil, {t=0}, {t=0}, {[1]=false, [16]=false}
 for j = 1, 64 do trks[i].steps[j], trks[i].ratch[j] = 0, false end
end

local vel_led, next_vel = {[32]=3, [64]=6, [96]=10, [127]=15}, {[32]=64, [64]=96, [96]=127, [127]=32}
local bpm, taps = 120, {}

local function load_psets()
 for y = 1, #trks do for x = 1, 8 do local d = pset_read((y * 10) + x); if d then presets[y][x] = d end end end
 local gst = pset_read(100)
 if gst then
  if gst.bpm then bpm = gst.bpm end
  for y = 1, #trks do
   local px = gst[y]; if px and presets[y][px] then
    act_pset[y] = px; local p = presets[y][px]
    trks[y].len = p.len or p.length or trks[y].len
    trks[y].mute = p.mute ~= nil and p.mute or (p.muted ~= nil and p.muted) or false
    trks[y].note = p.note or trks[y].note
    trks[y].ch = p.ch or p.channel or trks[y].ch
    trks[y].swing = p.swing or 50
    trks[y].m_time = p.m_time or p.micro_timing or 0
    
    local src_steps = p.steps or {}
    local src_ratch = p.ratch or p.ratchets or {}
    for i = 1, 64 do 
     trks[y].steps[i] = src_steps[i] or 0
     trks[y].ratch[i] = src_ratch[i] or false 
    end
   end
  end
 end
end
load_psets()

local is_play, play_start, cur_step = false, 0, 0 
local pages = { notes=false, bpm=false, perf=false, shift=false, swing=false, len=false }
local function tog_page(n) pages[n] = not pages[n]; for k in pairs(pages) do if k ~= n then pages[k] = false end end end

local mod_st = { perf={}, swing={}, notes={}, len={} }
local function handle_mod(id, z)
 local m = mod_st[id]
 if z == 1 then m.held, m.mod, m.was_act = true, false, pages[id]; if not pages[id] then tog_page(id) end
 else m.held = false; if m.mod ~= m.was_act then tog_page(id) end end
 grid_dirty = true
end

local sel_trk, sel_off_trk, sel_chan_trk = 1, nil, nil
local view_page, page_pin, page_held = 1, false, nil

local play_held, play_down_t, play_clear, play_blink_t, play_mod = false, 0, false, 0, false
local vel_held, def_vel, vel_mod = false, 96, false
local ratch_held, def_ratch, ratch_mod = false, false, false
local pend_save = false

local clk_src, clk_divs, ext_div = 1, {1, 2, 4, 8, 16}, 1
local ext_ticks, last_beat_t, ext_beats = 0, 0, 0
local ppqn, is_start = 23, false

local cyc_ord, cyc_idx, cyc_trk = {}, 0, nil
local cyc_next, cyc_anch, cyc_beat = 0, 0, 0

local function eff_bpm() return clk_src == 2 and (bpm / clk_divs[ext_div]) or bpm end
local function rep_per(col) local b = 60 / eff_bpm(); return (col == 12) and b or ((col == 13) and (b/2) or (b/4)) end
local function step_off(t, idx, s_time) return ((idx % 2 == 0) and (s_time * ((t.swing - 50) / 50)) or 0) + (t.m_time or 0) / 1000 end
local function next_grid_t(p) return (not is_play or p <= 0) and sys_time or (sys_time + ((p - ((sys_time - play_start) % p)) % p)) end

local function note_on(i, v)
 local c = trks[i].ch
 if c == 0 then for x = 1, 16 do midi_tx(143 + x, trks[i].note, v or def_vel) end else midi_tx(143 + c, trks[i].note, v or def_vel) end
 trks[i].p_note = true
end

local function note_off(i)
 if trks[i].p_note then
  local c = trks[i].ch
  if c == 0 then for x = 1, 16 do midi_tx(127 + x, trks[i].note, 0) end else midi_tx(127 + c, trks[i].note, 0) end
  trks[i].p_note = false
 end
end

local function increment_btns() grid_led(13,4,12); grid_led(13,5,6); grid_led(13,7,12); grid_led(13,8,6) end

local sys_m = metro.init(function()
 sys_time = sys_time + 0.01
 if pend_save then act_pset.bpm = bpm; pset_write(100, act_pset); pend_save = false end

 if play_held and not play_clear and not play_mod and (sys_time - play_down_t) >= 2.0 then
  for i, t in ipairs(trks) do note_off(i); for j = 1, 64 do t.steps[j], t.ratch[j] = 0, false end; t.len = 16 end
  for k in pairs(pages) do pages[k] = false end
  def_vel, def_ratch, view_page, page_pin = 96, false, 1, false
  play_clear, play_blink_t, grid_dirty = true, sys_time, true
 end
 if play_blink_t > 0 and (sys_time - play_blink_t) >= 0.75 then play_blink_t = 0; grid_dirty = true end

 for y, t in ipairs(trks) do
  local h = p_held[y]
  if h.x and not h.saved and (sys_time - h.t) >= 2.0 then
   local px = h.x
   local function s_trk(i, sl)
    local p = { steps={}, ratch={}, len=trks[i].len, mute=trks[i].mute, note=trks[i].note, ch=trks[i].ch, swing=trks[i].swing, m_time=trks[i].m_time }
    for j = 1, 64 do p.steps[j], p.ratch[j] = trks[i].steps[j], trks[i].ratch[j] end
    presets[i][sl], act_pset[i], p_blink[i] = p, sl, {x=sl, t=sys_time}; pset_write((i * 10) + sl, p)
   end
   if mod_st.perf.held then for i=1, #trks do s_trk(i, px) end else s_trk(y, px) end
   h.saved, pend_save, grid_dirty = true, true, true
  end
  if p_blink[y].x and (sys_time - p_blink[y].t) >= 0.75 then p_blink[y] = {t=0}; grid_dirty = true end

  if t.rep_col and sys_time >= t.rep_next then
   note_off(y); if not t.mute then note_on(y, def_vel) else t.p_note = false end
   t.rep_cnt = t.rep_cnt + 1
   t.rep_next = t.rep_anch + (t.rep_cnt + 1) * t.rep_per + step_off(t, t.rep_cnt + 1, t.rep_per)
  end
 end

 if #cyc_ord > 0 then
  local cp = rep_per(14) 
  if cyc_anch == 0 then cyc_anch, cyc_next, cyc_beat = next_grid_t(cp), next_grid_t(cp) + cp, 0 end
  if sys_time >= cyc_next then
   if cyc_trk then note_off(cyc_trk) end
   cyc_idx = (cyc_idx % #cyc_ord) + 1; local idx = cyc_ord[cyc_idx]
   if not trks[idx].mute then note_on(idx, def_vel); cyc_trk = idx end
   cyc_beat = cyc_beat + 1
   cyc_next = cyc_anch + (cyc_beat + 1) * cp + step_off(trks[idx], cyc_beat + 1, cp)
  end
 else
  if cyc_trk then note_off(cyc_trk) end; cyc_idx, cyc_next, cyc_anch, cyc_beat, cyc_trk = 0, 0, 0, 0, nil
 end
end, 0.01); sys_m:start()

local pend_hits, swing_m = {}
swing_m = metro.init(function()
 local due, rem = {}, {}
 for _, h in ipairs(pend_hits) do table.insert(h.t <= sys_time + 0.005 and due or rem, h) end; pend_hits = rem
 for _, h in ipairs(due) do
  local t = trks[h.trk]
  if h.k == "off" then note_off(h.trk)
  elseif h.k == "on" then
   note_off(h.trk)
   if h.ratch then
    t.r_vel = h.val; local c = t.ch
    if c == 0 then for i=1,16 do midi_tx(143 + i, t.note, math.max(1, h.val - 15)) end else midi_tx(143 + c, t.note, math.max(1, h.val - 15)) end
    table.insert(pend_hits, {t = sys_time + h.s_time / 2, trk = h.trk, k = "r_redo"})
   else note_on(h.trk, h.val) end
   t.p_note = true
  elseif h.k == "r_redo" then note_off(h.trk); note_on(h.trk, t.r_vel or def_vel) end
 end
 if #pend_hits > 0 then table.sort(pend_hits, function(a, b) return a.t < b.t end); swing_m:start(math.max(0.001, pend_hits[1].t - sys_time), 1) end
end, 0.1, 1)

local function clock_tick()
 if clk_src == 1 then midi_tx(248) end
 local n_tick, sixteenth = ((ppqn % 12) + 1) % 12, ppqn % 6
 
 if (sixteenth + 1) % 6 == 0 then
  local m_len = 0; for _, t in ipairs(trks) do if t.len > m_len then m_len = t.len end end
  cur_step = m_len > 0 and ((cur_step % m_len) + 1) or 1
  for _, t in ipairs(trks) do t.pos = (t.pos % t.len) + 1 end
 end
 
 local s_time, t_sec = (60 / eff_bpm()) / 4, (60 / eff_bpm()) / 24
 local rep_act = false; for _, t in ipairs(trks) do if t.rep_col then rep_act = true; break end end
 
 if not rep_act and #cyc_ord == 0 then
  for i, t in ipairs(trks) do
   if not t.rep_col and i ~= cyc_trk then
    local e_tick = clamp(math.floor(12 * (t.swing / 100) + 0.5), 3, 9)
    if n_tick == 0 or n_tick == e_tick then
     local v = t.steps[t.pos]
     if v > 0 and not t.mute then
      local delay = (is_start and 0 or t_sec) + (t.m_time or 0) / 1000
      if delay < 0.001 then delay = 0.001 end
      local f_time = sys_time + delay
      if t.p_note then table.insert(pend_hits, { t = f_time - 0.001, trk = i, k = "off" }) end
      table.insert(pend_hits, { t = f_time, trk = i, k = "on", ratch = t.ratch[t.pos], val = v, s_time = s_time })
      table.insert(pend_hits, { t = f_time + math.max(0.01, s_time * 0.45), trk = i, k = "off" })
     end
    end
   end
  end
 end
 if #pend_hits > 0 then table.sort(pend_hits, function(a, b) return a.t < b.t end); swing_m:start(math.max(0.001, pend_hits[1].t - sys_time), 1) end
 is_start, ppqn, grid_dirty = false, ppqn + 1, true
end
m = metro.init(clock_tick, (60 / bpm) / 24)

function event_midi(d1, d2, d3)
 if clk_src == 2 then
  if d1 == 248 then
   ext_beats = ext_beats + 1
   if ext_beats >= 24 then
    if last_beat_t > 0 and (sys_time - last_beat_t) > 0 then
     local e_bpm = 60 / (sys_time - last_beat_t)
     if e_bpm >= 20 and e_bpm <= 300 then bpm = (bpm * 0.8) + (e_bpm * 0.2); update_tempo() end
    end
    last_beat_t, ext_beats = sys_time, 0
   elseif last_beat_t == 0 then last_beat_t = sys_time end
   
   if is_play then ext_ticks = (ext_ticks + 1) % clk_divs[ext_div]; if ext_ticks == 0 then clock_tick() end end
  elseif d1 == 250 or d1 == 251 then 
   is_play, play_start, ext_ticks, cur_step, is_start, ppqn = true, sys_time, 0, 0, true, 23
   for _, t in ipairs(trks) do t.pos = 0 end; last_beat_t, ext_beats, grid_dirty = 0, 0, true
  elseif d1 == 252 then is_play, grid_dirty = false, true; for i = 1, #trks do note_off(i) end end
 end
end

local b_blink, r_blink = true, true
b_m = metro.init(function() b_blink = not b_blink; grid_dirty = true end, (60 / bpm) / 2); b_m:start()
rb_m = metro.init(function() r_blink = not r_blink; grid_dirty = true end, (60 / bpm) / 4); rb_m:start()

function update_tempo()
 local b = 60 / eff_bpm(); m.time, b_m.time, rb_m.time = b/24, b/2, b/4 
 for _, t in ipairs(trks) do if t.rep_col then t.rep_per = rep_per(t.rep_col) end end
end; update_tempo()

local function get_pg() return page_pin and view_page or math.max(1, math.ceil((cur_step == 0 and 1 or cur_step) / 16)) end

function event_grid(x, y, z)
 if y == 1 then
  if x == 16 then handle_mod("perf", z); return
  elseif x == 4 then handle_mod("swing", z); return
  elseif x == 15 then handle_mod("notes", z); return
  elseif x == 10 then handle_mod("len", z); return end

  if x >= 6 and x <= 9 then
   if z == 1 then
    if mod_st.len.held then mod_st.len.mod = true; for i=1, #trks do trks[i].len = (x - 5) * 16 end
    elseif page_held and page_held ~= x then
     local src, dst = page_held - 5, x - 5
     for t=1, #trks do for i=1, 16 do
      trks[t].steps[(dst-1)*16 + i], trks[t].ratch[(dst-1)*16 + i] = trks[t].steps[(src-1)*16 + i], trks[t].ratch[(src-1)*16 + i]
     end end
    else
     page_held = x; for k in pairs(pages) do pages[k] = false end
     local tp = x - 5; if page_pin and view_page == tp then page_pin = false else page_pin, view_page = true, tp end
    end
   else if page_held == x then page_held = nil end end
   grid_dirty = true; return
  end

  if z == 1 then
   if x == 1 then play_held, play_down_t, play_clear, play_mod = true, sys_time, false, false
   elseif x == 2 then cur_step = 0; for i=1, #trks do trks[i].pos = 0 end
   elseif x == 3 then tog_page("bpm")
   elseif x == 11 then tog_page("shift")
   elseif x == 13 then vel_held, vel_mod = true, false
   elseif x == 14 then ratch_held, ratch_mod = true, false end
   grid_dirty = true
  else
   if x == 1 then
    play_held = false
    if not play_clear and not play_mod then 
     is_play = not is_play
     if is_play then play_start, is_start, ppqn, cur_step = sys_time, true, 23, 0
      for i = 1, #trks do trks[i].pos = 0 end
      if clk_src == 1 then m:start(); midi_tx(250); clock_tick() end
     else if clk_src == 1 then m:stop(); midi_tx(252) end; for i = 1, #trks do note_off(i) end end
    end
   elseif x == 13 then vel_held = false; if not vel_mod then def_vel = next_vel[def_vel] end
   elseif x == 14 then ratch_held = false; if not ratch_mod then def_ratch = not def_ratch end end
   grid_dirty = true
  end
  return
 end

 local trk = y - 1
 if trk >= 1 and trk <= #trks then
  if play_held and x == 1 then
   if z == 1 then note_off(trk); for i=1, 64 do trks[trk].steps[i], trks[trk].ratch[i] = 0, false end; play_mod, grid_dirty = true, true end
   return
  end

  if mod_st.len.held and z == 1 then
   local idx = math.max(1, x + ((get_pg() - 1) * 16)); mod_st.len.mod = true
   for i=1, #trks do trks[i].len = idx end; grid_dirty = true; return
  end

  if pages.perf and x <= 8 then
   if z == 1 then p_held[trk] = {x = x, t = sys_time, saved = false}; if mod_st.perf.held then mod_st.perf.mod = true end
   elseif z == 0 and p_held[trk].x == x then
    if not p_held[trk].saved then
     local function ld(i, sl)
      note_off(i); local p = presets[i][sl]
      if p then trks[i].len, trks[i].mute, trks[i].note, trks[i].ch, trks[i].swing, trks[i].m_time = p.len, p.mute ~= nil and p.mute or (p.muted ~= nil and p.muted) or false, p.note or trks[i].note, p.ch or p.channel or 10, p.swing or 50, p.m_time or p.micro_timing or 0
       local src_steps = p.steps or {}
       local src_ratch = p.ratch or p.ratchets or {}
       for j=1, 64 do trks[i].steps[j], trks[i].ratch[j] = src_steps[j] or 0, src_ratch[j] or false end
      else for j=1, 64 do trks[i].steps[j], trks[i].ratch[j] = 0, false end; trks[i].len, trks[i].swing, trks[i].m_time = 16, 50, 0 end
      act_pset[i] = sl
     end
     if mod_st.perf.held then for i = 1, #trks do ld(i, x) end else ld(trk, x) end; pend_save = true
    end
    p_held[trk] = {t = 0}; grid_dirty = true
   end 
   return
  end

  if x >= 12 and x <= 14 then
   if z == 1 and pages.perf then
    local t = trks[trk]; t.rep_col, t.rep_per, t.rep_cnt = x, rep_per(x), 0
    t.rep_anch = next_grid_t(t.rep_per); t.rep_next = t.rep_anch + t.rep_per + step_off(t, 1, t.rep_per)
    grid_dirty = true; return
   elseif z == 0 and trks[trk].rep_col == x then trks[trk].rep_col = nil; note_off(trk); grid_dirty = true; return end
  end

  if x == 10 then
   if z == 1 and pages.perf then table.insert(cyc_ord, trk); grid_dirty = true; return
   elseif z == 0 then for i, id in ipairs(cyc_ord) do if id == trk then table.remove(cyc_ord, i); break end end; grid_dirty = true; return end
  end

  if pages.shift and (x == 1 or x == 16) then
   shft_press[trk][x] = (z == 1)
   if z == 1 then
    local a1, a2, l, d = trks[trk].steps, trks[trk].ratch, trks[trk].len, x==1 and -1 or 1
    if l > 1 then
     local t1, t2 = a1[d>0 and l or 1], a2[d>0 and l or 1]
     if d > 0 then for i=l, 2, -1 do a1[i], a2[i] = a1[i-1], a2[i-1] end; a1[1], a2[1] = t1, t2
     else for i=1, l-1 do a1[i], a2[i] = a1[i+1], a2[i+1] end; a1[l], a2[l] = t1, t2 end
    end
   end
   grid_dirty = true; return
  end

  if z == 1 then
   if pages.notes then
    if x == 15 then sel_trk, sel_chan_trk = trk, nil; grid_dirty = true
    elseif x == 16 then sel_chan_trk = trk; grid_dirty = true
    elseif sel_chan_trk then 
     if adj_btns(x, y, function() return trks[sel_chan_trk].ch end, function(v) note_off(sel_chan_trk); trks[sel_chan_trk].ch = v; if mod_st.notes.held then mod_st.notes.mod = true; for i=1, #trks do note_off(i); trks[i].ch = v end end end, 1, 5, 0, 16) then grid_dirty = true end
    else 
     if adj_btns(x, y, function() return trks[sel_trk].note end, function(v) note_off(sel_trk); trks[sel_trk].note = v; if mod_st.notes.held then mod_st.notes.mod = true; for i=1, #trks do note_off(i); trks[i].note = v end end end, 1, 5, 0, 127) then grid_dirty = true end 
    end
   elseif pages.bpm then
    if x == 1 and y == 2 then
     if #taps > 0 and (sys_time - taps[#taps]) > 2.0 then taps = {} end
     if #taps > 0 and (sys_time - taps[#taps]) < 0.1 then return end
     table.insert(taps, sys_time)
     if #taps > 1 then local d = (sys_time - taps[1])/(#taps - 1); if d > 0 then bpm = math.floor(clamp(60/d, 20, 300)); update_tempo() end end
     if #taps > 4 then table.remove(taps, 1) end
     grid_dirty = true; return
    end
    if x == 3 and y == 2 then clk_src = 1; update_tempo(); if is_play then m:start() end; grid_dirty = true; return end
    if x == 4 and y == 2 then clk_src = 2; update_tempo(); m:stop(); grid_dirty = true; return end
    if clk_src == 2 and y == 2 and x >= 6 and x <= 10 then ext_div = x - 5; update_tempo(); grid_dirty = true; return end
    if clk_src == 1 and adj_btns(x, y, function() return bpm end, function(v) bpm = v; update_tempo() end, 1, 10, 20, 300) then grid_dirty = true end
   elseif pages.perf then
    if x == 16 then 
     if mod_st.perf.held then mod_st.perf.mod = true; local m = trks[trk].mute; for i=1, #trks do trks[i].mute = not m end else trks[trk].mute = not trks[trk].mute end
     grid_dirty = true 
    end
   elseif pages.swing then
    if x == 15 then sel_trk, sel_off_trk = trk, nil; grid_dirty = true
    elseif x == 16 then sel_off_trk = trk; grid_dirty = true
    elseif sel_off_trk then 
     if adj_btns(x, y, function() return trks[sel_off_trk].m_time end, function(v) trks[sel_off_trk].m_time = v if mod_st.swing.held then mod_st.swing.mod = true for i=1, #trks do trks[i].m_time = v end end end, 1, 5, -50, 50) then grid_dirty = true end
    else 
     if adj_btns(x, y, function() return trks[sel_trk].swing end, function(v) trks[sel_trk].swing = v if mod_st.swing.held then mod_st.swing.mod = true for i=1, #trks do trks[i].swing = v end end end, 1, 5, 25, 75) then grid_dirty = true end 
    end
   else
    if not pages.shift then
     local idx = math.max(1, x + ((get_pg() - 1) * 16))
     if pages.len then trks[trk].len = idx
     elseif ratch_held then ratch_mod = true; if trks[trk].steps[idx] > 0 then trks[trk].ratch[idx] = not trks[trk].ratch[idx] end
     elseif vel_held then vel_mod = true; if trks[trk].steps[idx] > 0 then trks[trk].steps[idx] = next_vel[trks[trk].steps[idx]] end
     else if trks[trk].steps[idx] > 0 then trks[trk].steps[idx], trks[trk].ratch[idx] = 0, false else trks[trk].steps[idx], trks[trk].ratch[idx] = def_vel, def_ratch end end
     grid_dirty = true
    end
   end
  end
 end
end

local function hardware_redraw()
 grid_led_all(0)
 local p_br = math.floor(4 + 2 * math.sin(sys_time * 4))
 
 grid_led(1, 1, (play_blink_t > 0 and (sys_time - play_blink_t) < 0.75) and (r_blink and 15 or 0) or (is_play and 15 or 4))
 grid_led(2, 1, 4)
 grid_led(3, 1, b_blink and 15 or (pages.bpm and 8 or 4))
 grid_led(4, 1, pages.swing and 15 or 4)
 
 local c_pg, ph_pg = get_pg(), math.max(1, math.ceil((cur_step == 0 and 1 or cur_step) / 16))
 local m_len = 0; for _, t in ipairs(trks) do if t.len > m_len then m_len = t.len end end; m_len = m_len > 0 and m_len or 64
 for px = 6, 9 do local pg = px - 5; grid_led(px, 1, c_pg ~= pg and (((pg - 1) * 16 < m_len) and 4 or 1) or (ph_pg == pg and 15 or 10)) end
 
 grid_led(10, 1, pages.len and p_br or 4); grid_led(11, 1, pages.shift and 15 or 4)
 grid_led(13, 1, vel_held and 15 or (vel_led[def_vel] or 0))
 grid_led(14, 1, ratch_held and 15 or (def_ratch and (r_blink and 15 or 4) or 4))
 grid_led(15, 1, pages.notes and 15 or 4); grid_led(16, 1, pages.perf and 15 or 4)

 if pages.notes then
  for i=1, #trks do 
   local c1, c2 = (not sel_chan_trk and i == sel_trk) and 15 or 4, (i == sel_chan_trk) and 15 or 4
   if mod_st.notes.held then if sel_chan_trk then c2 = 15 else c1 = 15 end end
   grid_led(15, i+1, c1); grid_led(16, i+1, c2) 
  end
  if sel_chan_trk then draw_text(trks[sel_chan_trk].ch == 0 and "ALL" or trks[sel_chan_trk].ch, 1, 4) else draw_text(trks[sel_trk].note, 1, 4) end
  increment_btns()
 elseif pages.bpm then
  grid_led(1, 2, b_blink and 15 or 4); grid_led(3, 2, clk_src == 1 and 15 or 4); grid_led(4, 2, clk_src == 2 and 15 or 4)
  if clk_src == 2 then draw_text("EXT", 1, 4); for i=1, #clk_divs do grid_led(i+5, 2, ext_div==i and 15 or 4) end
  else draw_text(math.floor(bpm + 0.5), 1, 4); increment_btns() end
 elseif pages.perf then
  for y = 1, #trks do
   for x = 1, 8 do
    local p, has_s = presets[y][x], false
    if p then for i=1, 64 do if (p.steps[i] or 0) > 0 then has_s = true; break end end end
    grid_led(x, y+1, (p_blink[y].x == x) and (r_blink and 15 or 0) or (act_pset[y] == x and 15 or (p and has_s and 6 or 2)))
   end
   grid_led(16, y+1, trks[y].mute and 0 or 10)
   local isc = false; for _, id in ipairs(cyc_ord) do if id == y then isc = true; break end end
   grid_led(10, y+1, isc and 15 or 4)
   for _, c in ipairs({12,13,14}) do grid_led(c, y+1, trks[y].rep_col == c and 15 or 4) end
  end
 elseif pages.swing then
  for i=1, #trks do 
   local c1, c2 = (not sel_off_trk and i == sel_trk) and 15 or 4, (i == sel_off_trk) and 15 or 4
   if mod_st.swing.held then if sel_off_trk then c2 = 15 else c1 = 15 end end
   grid_led(15, i+1, c1); grid_led(16, i+1, c2) 
  end
  if sel_off_trk then local mt = trks[sel_off_trk].m_time; draw_text(mt > 0 and ("+" .. mt) or mt, 1, 4) else draw_text(trks[sel_trk].swing .. "%", 1, 4) end
  increment_btns()
 else
  local off = (c_pg - 1) * 16
  for y = 1, #trks do
   local sidx = trks[y].pos; if sidx == 0 then sidx = 1 end
   for x = 1, 16 do
    local idx, val, br = x + off, trks[y].steps[x + off], vel_led[trks[y].steps[x + off]] or 0
    if val > 0 and trks[y].ratch[idx] then br = r_blink and br or 1 end
    if idx == sidx then br = val > 0 and 15 or 12 end
    if pages.len and idx == trks[y].len then br = (val == 0 and idx ~= sidx) and p_br or br end
    if pages.shift and (x == 1 or x == 16) then br = shft_press[y][x] and 15 or ((val == 0 and idx ~= sidx) and 2 or br) end
    grid_led(x, y+1, br)
   end
  end
 end
 grid_refresh()
end

local render_m = metro.init(function() if grid_dirty then hardware_redraw(); grid_dirty = false end end, 1/30)
render_m:start()
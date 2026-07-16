-- Stepiii
pset_init("stepiii")

local font = {
  [0]="011101101101110", [1]="010110010010111", [2]="110001111100111",
  [3]="110001111001111", [4]="101101111001001", [5]="111100111001110",
  [6]="011100111101111", [7]="111001010010010", [8]="011101111101110",
  [9]="111101111001110", ["-"]="000000111000000", ["+"]="000010111010000",
  ["E"]="111100110100111", ["X"]="101101010101101", ["T"]="111010010010010"
}

local function draw_digit(digit, start_x, start_y)
  local pat = font[digit]
  if not pat then return end 
  for i = 1, 15 do
    if pat:sub(i, i) == "1" then
      grid_led(start_x + ((i-1)%3), start_y + math.floor((i-1)/3), 5) 
    end
  end
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function handle_adjust_buttons(x, y, get, set, small, big, lo, hi)
  if x == 4 then
    if y == 1 then set(clamp(get() + small, lo, hi)); return true end
    if y == 2 then set(clamp(get() - small, lo, hi)); return true end
    if y == 4 then set(clamp(get() + big, lo, hi)); return true end
    if y == 5 then set(clamp(get() - big, lo, hi)); return true end
  end
  return false
end

local tracks, presets, active_preset, preset_held, preset_blink, shift_pressed = {}, {}, {}, {}, {}, {}
local notes = {36, 38, 42, 46, 41, 49, 51}

for i, n in ipairs(notes) do
  tracks[i] = { note = n, channel = 10, steps = {}, ratchets = {}, length = 16, muted = false, swing = 50, micro_timing = 0, pos = 0 }
  presets[i], active_preset[i] = {}, nil
  preset_held[i], preset_blink[i] = {time = 0}, {time = 0}
  shift_pressed[i] = {[1] = false, [16] = false}
  for j = 1, 32 do tracks[i].steps[j], tracks[i].ratchets[j] = 0, false end
end

local vel_led = {[32]=3, [64]=6, [96]=10, [127]=15}
local next_vel = {[32]=64, [64]=96, [96]=127, [127]=32}

local function save_preset(y, x) pset_write((y * 10) + x, presets[y][x]) end

local function load_all_presets()
  for y = 1, #tracks do
    for x = 1, 8 do
      local data = pset_read((y * 10) + x)
      if data then presets[y][x] = data end
    end
  end
  
  local global_state = pset_read(100)
  if global_state then
    if global_state.bpm then bpm = global_state.bpm end
    for y = 1, #tracks do
      local px = global_state[y]
      if px and presets[y][px] then
        active_preset[y] = px
        local p = presets[y][px]
        tracks[y].length, tracks[y].muted, tracks[y].note, tracks[y].channel = p.length, p.muted or false, p.note or tracks[y].note, p.channel or 10
        tracks[y].swing, tracks[y].micro_timing = p.swing or 50, p.micro_timing or 0
        for i = 1, 32 do tracks[y].steps[i], tracks[y].ratchets[i] = p.steps[i], p.ratchets[i] end
      end
    end
  end
end

load_all_presets()

local playing, playback_start_time, current_step = false, 0, 0 
local pages = { notes = false, bpm = false, perform = false, shift = false, swing = false, length = false }
local function toggle_page(name)
  pages[name] = not pages[name]
  for k in pairs(pages) do if k ~= name then pages[k] = false end end
end
local selected_track, selected_offset_track, selected_channel_track = 1, nil, nil
local view_page, page_pinned = 1, false
local bpm, taps = 120, {}

local play_btn_held, play_btn_down_time, play_btn_cleared = false, 0, false
local vel_btn_held, default_velocity, vel_used_as_modifier = false, 96, false
local ratchet_btn_held, default_ratchet, ratchet_used_as_modifier = false, false, false
local length_btn_down = false

local clock_source, clock_divs, ext_div_idx = 1, {1, 2, 4, 8, 16}, 1
local ext_tick_counter, last_beat_time, ext_beat_ticks = 0, 0, 0

local cycle_held_order, cycle_index, cycle_active_track = {}, 0, nil
local next_cycle_time, cycle_anchor_time, cycle_beat_count, sys_time = 0, 0, 0, 0

local function get_effective_bpm() return clock_source == 2 and (bpm / clock_divs[ext_div_idx]) or bpm end
local function repeat_period(col)
  local b = 60 / get_effective_bpm()
  return (col == 12) and b or ((col == 13) and (b/2) or (b/4))
end
local function compute_step_offset(track, step_index, step_time)
  local swing_delay = (step_index % 2 == 0 and track.swing and track.swing > 50) and (step_time * (2 * (track.swing / 100) - 1)) or 0
  return swing_delay + (track.micro_timing or 0) / 1000
end
local function next_grid_time(period)
  if not playing or period <= 0 then return sys_time end
  return sys_time + ((period - ((sys_time - playback_start_time) % period)) % period)
end

-- NEW HELPER FUNCTIONS
local function note_on(trk, vel)
  midi_tx(143 + tracks[trk].channel, tracks[trk].note, vel or default_velocity)
  tracks[trk].playing_note = true
end

local function note_off(trk)
  if tracks[trk].playing_note then
    midi_tx(127 + tracks[trk].channel, tracks[trk].note, 0)
    tracks[trk].playing_note = false
  end
end

local function clear_track_data(t)
  for i = 1, 32 do t.steps[i], t.ratchets[i] = 0, false end
end

local function reset_track(t)
  clear_track_data(t)
  t.length, t.pos = 16, 0 
end

local function increment_btns()
  grid_led(4,1,12); grid_led(4,2,6); grid_led(4,4,12); grid_led(4,5,6)
end

-- REFACTORED SYS_M
local sys_m = metro.init(function()
  sys_time = sys_time + 0.01
  if play_btn_held and not play_btn_cleared and (sys_time - play_btn_down_time) >= 2.0 then
    for i = 1, #tracks do reset_track(tracks[i]) end
    for k in pairs(pages) do pages[k] = false end
    default_velocity, default_ratchet = 96, false
    view_page, page_pinned = 1, false
    play_btn_cleared = true; draw()
  end
  for py = 1, #tracks do
    local held = preset_held[py]
    if held.x and not held.saved and (sys_time - held.time) >= 2.0 then
      local px = held.x
      presets[py][px] = { steps = {}, ratchets = {}, length = tracks[py].length, muted = tracks[py].muted, note = tracks[py].note, channel = tracks[py].channel, swing = tracks[py].swing, micro_timing = tracks[py].micro_timing }
      for i = 1, 32 do presets[py][px].steps[i], presets[py][px].ratchets[i] = tracks[py].steps[i], tracks[py].ratchets[i] end
      active_preset[py], held.saved, preset_blink[py] = px, true, {x = px, time = sys_time}
      active_preset.bpm = bpm
      save_preset(py, px); pset_write(100, active_preset); draw()
    end
    if preset_blink[py].x and (sys_time - preset_blink[py].time) >= 0.75 then preset_blink[py] = {time = 0}; draw() end
  end
  for i, t in ipairs(tracks) do
    if t.repeat_col and sys_time >= t.next_repeat_time then
      if t.playing_note then note_off(i) end
      if not t.muted then note_on(i, default_velocity) else t.playing_note = false end
      t.repeat_hit_count = t.repeat_hit_count + 1
      t.next_repeat_time = t.repeat_anchor_time + (t.repeat_hit_count + 1) * t.repeat_period + compute_step_offset(t, t.repeat_hit_count + 1, t.repeat_period)
    end
  end
  local cycle_active = #cycle_held_order > 0
  if cycle_active then
    local cp = repeat_period(14) 
    if cycle_anchor_time == 0 then cycle_anchor_time, next_cycle_time, cycle_beat_count = next_grid_time(cp), next_grid_time(cp) + cp, 0 end
    if sys_time >= next_cycle_time then
      if cycle_active_track then note_off(cycle_active_track) end
      cycle_index = (cycle_index % #cycle_held_order) + 1
      local tidx = cycle_held_order[cycle_index]
      if not tracks[tidx].muted then note_on(tidx, default_velocity); cycle_active_track = tidx end
      cycle_beat_count = cycle_beat_count + 1
      next_cycle_time = cycle_anchor_time + (cycle_beat_count + 1) * cp + compute_step_offset(tracks[tidx], cycle_beat_count + 1, cp)
    end
  else
    if cycle_active_track then note_off(cycle_active_track) end
    cycle_index, next_cycle_time, cycle_anchor_time, cycle_beat_count, cycle_active_track = 0, 0, 0, 0, nil
  end
end, 0.01)
sys_m:start()

local midi_clock_m = metro.init(function() midi_tx(248) end, (60 / bpm) / 24)

local function update_tempo()
  local b = 60 / get_effective_bpm()
  m.time, blink_m.time, ratchet_blink_m.time = b/4, b/2, b/4      
  midi_clock_m.time = (60 / bpm) / 24 
  for _, t in ipairs(tracks) do if t.repeat_col then t.repeat_period = repeat_period(t.repeat_col) end end
end

local pending_ratchet_hits = {}
local ratchet_metro = metro.init(function()
  for _, i in ipairs(pending_ratchet_hits) do
    midi_tx(127 + tracks[i].channel, tracks[i].note, 0); midi_tx(143 + tracks[i].channel, tracks[i].note, tracks[i].ratchet_vel or default_velocity); tracks[i].playing_note = true
  end
  pending_ratchet_hits = {}
end, 0.1, 1)

local pending_swing_hits = {}
local swing_metro
swing_metro = metro.init(function()
  local due, remaining = {}, {}
  for _, hit in ipairs(pending_swing_hits) do table.insert(hit.time <= sys_time + 0.005 and due or remaining, hit) end
  pending_swing_hits = remaining
  for _, hit in ipairs(due) do
    local t = tracks[hit.track]
    if hit.kind == "note_on" then
      if hit.is_ratch then
        t.ratchet_vel = hit.step_val
        midi_tx(143 + t.channel, t.note, math.max(1, hit.step_val - 15))
        table.insert(pending_swing_hits, {time = sys_time + hit.step_time / 2, track = hit.track, kind = "ratchet_redo"})
      else
        midi_tx(143 + t.channel, t.note, hit.step_val)
      end
      t.playing_note = true
    elseif hit.kind == "ratchet_redo" then
      midi_tx(127 + t.channel, t.note, 0); midi_tx(143 + t.channel, t.note, t.ratchet_vel or default_velocity); t.playing_note = true
    end
  end
  if #pending_swing_hits > 0 then
    table.sort(pending_swing_hits, function(a, b) return a.time < b.time end)
    swing_metro:start(math.max(0.001, pending_swing_hits[1].time - sys_time), 1)
  end
end, 0.1, 1)

local function start_repeat(i, col)
  local t = tracks[i]
  t.repeat_col, t.repeat_period, t.repeat_hit_count = col, repeat_period(col), 0
  t.repeat_anchor_time = next_grid_time(t.repeat_period)
  t.next_repeat_time = t.repeat_anchor_time + t.repeat_period + compute_step_offset(t, 1, t.repeat_period)
end
local function stop_repeat(i)
  tracks[i].repeat_col = nil
  if tracks[i].playing_note then midi_tx(127 + tracks[i].channel, tracks[i].note, 0); tracks[i].playing_note = false end
end
local function any_repeat_active() for i=1,#tracks do if tracks[i].repeat_col then return true end end return false end
local function advance_step()
  for i, t in ipairs(tracks) do if t.playing_note and not t.repeat_col and i ~= cycle_active_track then midi_tx(127 + t.channel, t.note, 0); t.playing_note = false end end
  local max_len = 0
  for i, t in ipairs(tracks) do if t.length > max_len then max_len = t.length end end
  current_step = max_len > 0 and ((current_step % max_len) + 1) or 1
  local step_time = (60 / get_effective_bpm()) / 4
  if not any_repeat_active() and #cycle_held_order == 0 then
    for i, t in ipairs(tracks) do
      t.pos = (t.pos % t.length) + 1
      local val = t.steps[t.pos]
      if t.early_fired_for == t.pos then t.early_fired_for = nil
      elseif val > 0 and not t.muted then
        local is_ratch, offset = t.ratchets[t.pos], compute_step_offset(t, t.pos, step_time)
        if offset > 0.001 then table.insert(pending_swing_hits, { time = sys_time + offset, track = i, kind = "note_on", is_ratch = is_ratch, step_val = val, step_time = step_time })
        elseif is_ratch then
          t.ratchet_vel = val; midi_tx(143 + t.channel, t.note, math.max(1, val - 15)); table.insert(pending_ratchet_hits, i); t.playing_note = true
        else midi_tx(143 + t.channel, t.note, val); t.playing_note = true end
      end
    end
    for i, t in ipairs(tracks) do
      local npos = (t.pos % t.length) + 1
      if t.steps[npos] > 0 and not t.muted and compute_step_offset(t, npos, step_time) < -0.001 then
        table.insert(pending_swing_hits, { time = sys_time + math.max(0.001, step_time + compute_step_offset(t, npos, step_time)), track = i, kind = "note_on", is_ratchet = t.ratchets[npos], step_val = t.steps[npos], step_time = step_time })
        t.early_fired_for = npos
      end
    end
  end
  if #pending_ratchet_hits > 0 then ratchet_metro:start(step_time / 2, 1) end
  if #pending_swing_hits > 0 then
    table.sort(pending_swing_hits, function(a, b) return a.time < b.time end)
    swing_metro:start(math.max(0.001, pending_swing_hits[1].time - sys_time), 1)
  end
end

m = metro.init(function() advance_step(); draw() end, (60 / bpm) / 4)

function event_midi(d1, d2, d3)
  if clock_source == 2 then
    if d1 == 248 then
      ext_beat_ticks = ext_beat_ticks + 1
      if ext_beat_ticks >= 24 then
        if last_beat_time > 0 and (sys_time - last_beat_time) > 0 then
          local ext_bpm = 60 / (sys_time - last_beat_time)
          if ext_bpm >= 20 and ext_bpm <= 300 then
            bpm = (bpm * 0.8) + (ext_bpm * 0.2) 
            update_tempo() 
          end
        end
        last_beat_time = sys_time
        ext_beat_ticks = 0
      elseif last_beat_time == 0 then
        last_beat_time = sys_time
      end
      if playing then
        ext_tick_counter = ext_tick_counter + 1
        if ext_tick_counter >= clock_divs[ext_div_idx] * 6 then 
          ext_tick_counter = 0
          advance_step()
          draw() 
        end
      end
    elseif d1 == 250 or d1 == 251 then 
      playing, playback_start_time, ext_tick_counter, current_step = true, sys_time, 0, 0
      for _, t in ipairs(tracks) do t.pos = 0 end
      last_beat_time, ext_beat_ticks = 0, 0
      draw()
    elseif d1 == 252 then 
      playing = false
      draw() 
    end
  end
end

local blink_state, ratchet_blink_state = true, true
blink_m = metro.init(function() blink_state = not blink_state; draw() end, (60 / bpm) / 2); blink_m:start()
ratchet_blink_m = metro.init(function() ratchet_blink_state = not ratchet_blink_state; draw() end, (60 / bpm) / 4); ratchet_blink_m:start()
update_tempo()

local function any_track_over_16() for i=1,#tracks do if tracks[i].length > 16 then return true end end return false end
local function current_view_page() return page_pinned and view_page or (any_track_over_16() and current_step > 16 and 2 or 1) end
local function shift_arr(arr, len, dir)
  if len < 2 then return end
  local temp = arr[dir>0 and len or 1]
  if dir > 0 then for i=len,2,-1 do arr[i]=arr[i-1] end arr[1]=temp
  else for i=1,len-1 do arr[i]=arr[i+1] end arr[len]=temp end
end

-- REFACTORED DISPATCH TABLE FOR EVENT GRID
local bottom_row_actions = {
  [2] = function() current_step = 0; for i=1,#tracks do tracks[i].pos = 0 end end,
  [3] = function() toggle_page("bpm") end,
  [12] = function() toggle_page("swing") end,
  [13] = function() toggle_page("shift") end,
  [15] = function() toggle_page("notes") end,
  [16] = function() toggle_page("perform") end
}

function event_grid(x, y, z)
  if z == 1 and y == 8 and bottom_row_actions[x] then 
    bottom_row_actions[x]()
    draw()
    return 
  end

  if x == 1 and y == 8 then
    if z == 1 then play_btn_held, play_btn_down_time, play_btn_cleared = true, sys_time, false
    elseif z == 0 then 
      play_btn_held = false
      if not play_btn_cleared then 
        playing = not playing
        if playing then playback_start_time = sys_time; if clock_source == 1 then m:start(); midi_clock_m:start(); midi_tx(250) end
        else if clock_source == 1 then m:stop(); midi_clock_m:stop(); midi_tx(252) end end
        draw() 
      end 
    end return 
  end
  if x == 9 and y == 8 then
    if z == 1 then vel_btn_held, vel_used_as_modifier = true, false
    elseif z == 0 then vel_btn_held = false; if not vel_used_as_modifier then default_velocity = next_vel[default_velocity] end end draw(); return
  end
  if x == 10 and y == 8 then
    if z == 1 then ratchet_btn_held, ratchet_used_as_modifier = true, false
    elseif z == 0 then ratchet_btn_held = false; if not ratchet_used_as_modifier then default_ratchet = not default_ratchet end end draw(); return
  end
  if x == 7 and y == 8 then
    if z == 1 then length_btn_down = true; toggle_page("length") else length_btn_down = false end
    draw(); return
  end
  
  if x == 5 and y == 8 and z == 1 then 
    if length_btn_down then 
      for i=1,#tracks do tracks[i].length=16 end 
    else 
      for k in pairs(pages) do pages[k]=false end
      if page_pinned and view_page == 1 then page_pinned = false else page_pinned, view_page = true, 1 end 
    end 
    draw(); return 
  end
  
  if x == 6 and y == 8 and z == 1 then 
    if length_btn_down then 
      for i=1,#tracks do tracks[i].length=32 end 
    else 
      for k in pairs(pages) do pages[k]=false end
      if page_pinned and view_page == 2 then page_pinned = false else page_pinned, view_page = true, 2 end 
    end 
    draw(); return 
  end

  if pages.perform and x <= 8 and y <= #tracks then
    if z == 1 then preset_held[y] = {x = x, time = sys_time, saved = false}
    elseif z == 0 and preset_held[y].x == x then
      if not preset_held[y].saved then
        local p = presets[y][x]
        if p then tracks[y].length, tracks[y].muted, tracks[y].note, tracks[y].channel, tracks[y].swing, tracks[y].micro_timing = p.length, p.muted or false, p.note or tracks[y].note, p.channel or 10, p.swing or 50, p.micro_timing or 0
          for i=1,32 do tracks[y].steps[i], tracks[y].ratchets[i] = p.steps[i], p.ratchets[i] end
        else reset_track(tracks[y]); tracks[y].swing, tracks[y].micro_timing = 50, 0 end
        active_preset[y] = x; active_preset.bpm = bpm; pset_write(100, active_preset)
      end
      preset_held[y] = {time = 0}; draw()
    end return
  end
  if (x == 12 or x == 13 or x == 14) and y <= #tracks then
    if z == 1 and pages.perform then start_repeat(y, x); draw(); return
    elseif z == 0 and tracks[y].repeat_col == x then stop_repeat(y); draw(); return end
  end
  if x == 10 and y <= #tracks then
    if z == 1 and pages.perform then table.insert(cycle_held_order, y); draw(); return
    elseif z == 0 then for i, trk in ipairs(cycle_held_order) do if trk == y then table.remove(cycle_held_order, i); break end end draw(); return end
  end
  if pages.shift and (x == 1 or x == 16) and y <= #tracks then
    shift_pressed[y][x] = (z == 1)
    if z == 1 then shift_arr(tracks[y].steps, tracks[y].length, x==1 and -1 or 1); shift_arr(tracks[y].ratchets, tracks[y].length, x==1 and -1 or 1) end
    draw(); return
  end
  if z == 1 then
    if pages.notes then
      if x == 1 and y <= #tracks then selected_track, selected_channel_track = y, nil; draw() 
      elseif x == 2 and y <= #tracks then selected_channel_track = y; draw()
      elseif selected_channel_track then if handle_adjust_buttons(x, y, function() return tracks[selected_channel_track].channel end, function(v) tracks[selected_channel_track].channel = v end, 1, 4, 1, 16) then draw() end
      else if handle_adjust_buttons(x, y, function() return tracks[selected_track].note end, function(v) tracks[selected_track].note = v end, 1, 10, 0, 127) then draw() end end
    elseif pages.bpm then
      if x == 1 and (y == 4 or y == 5) then clock_source = y == 4 and 1 or 2; update_tempo(); if clock_source==1 and playing then m:start(); midi_clock_m:start() else m:stop(); midi_clock_m:stop() end draw(); return end
      if clock_source == 2 and x == 4 and y <= #clock_divs then ext_div_idx = y; update_tempo(); draw(); return end
      if x == 1 and y == 1 then
        if #taps > 0 and (sys_time - taps[#taps]) < 0.1 then return end
        table.insert(taps, sys_time)
        if #taps > 1 then local d = (sys_time - taps[1])/(#taps - 1); if d > 0 then bpm = math.floor(clamp(60/d, 20, 300)); update_tempo() end end
        if #taps > 4 then table.remove(taps, 1) end; draw()
      end
      if clock_source == 1 and handle_adjust_buttons(x, y, function() return bpm end, function(v) bpm = v; update_tempo() end, 1, 10, 20, 300) then draw() end
    elseif pages.perform then
      if x == 16 and y <= #tracks then tracks[y].muted = not tracks[y].muted; draw() end
    elseif pages.swing then
      if x == 1 and y <= #tracks then selected_track, selected_offset_track = y, nil; draw()
      elseif x == 2 and y <= #tracks then selected_offset_track = y; draw()
      elseif selected_offset_track then if handle_adjust_buttons(x, y, function() return tracks[selected_offset_track].micro_timing end, function(v) tracks[selected_offset_track].micro_timing = v end, 1, 5, -50, 50) then draw() end
      else if handle_adjust_buttons(x, y, function() return tracks[selected_track].swing end, function(v) tracks[selected_track].swing = v end, 1, 5, 50, 75) then draw() end end
    else
      if y <= #tracks and not pages.shift then
        local idx = x + (current_view_page() == 2 and 16 or 0)
        if pages.length then tracks[y].length = idx
        elseif ratchet_btn_held then ratchet_used_as_modifier = true; if tracks[y].steps[idx] > 0 then tracks[y].ratchets[idx] = not tracks[y].ratchets[idx] end
        elseif vel_btn_held then vel_used_as_modifier = true; if tracks[y].steps[idx] > 0 then tracks[y].steps[idx] = next_vel[tracks[y].steps[idx]] end
        else
          if tracks[y].steps[idx] > 0 then tracks[y].steps[idx], tracks[y].ratchets[idx] = 0, false
          else tracks[y].steps[idx], tracks[y].ratchets[idx] = default_velocity, default_ratchet end
        end
        draw()
      end
    end
  end
end

-- REFACTORED DRAW FUNCTION
function draw()
  grid_led_all(0)
  local pulse_br = math.floor(4 + 2 * math.sin(sys_time * 4))
    if pages.notes then
      for i=1,#tracks do 
        grid_led(1, i, (not selected_channel_track and i == selected_track) and 15 or 4)
        grid_led(2, i, i == selected_channel_track and 15 or 4) 
      end
      if selected_channel_track then
        local c = tracks[selected_channel_track].channel
        if c >= 10 then draw_digit(math.floor(c/10), 10, 1) end
        draw_digit(c%10, 14, 1)
      else
        local n = tracks[selected_track].note; if n >= 100 then draw_digit(math.floor(n/100), 6, 1) end
        draw_digit(math.floor((n%100)/10), 10, 1); draw_digit(n%10, 14, 1)
      end
      increment_btns()
    elseif pages.bpm then
      grid_led(1, 1, blink_state and 15 or 4)
      if clock_source == 2 then draw_digit("E",6,1); draw_digit("X",10,1); draw_digit("T",14,1); for i=1,#clock_divs do grid_led(4,i, ext_div_idx==i and 15 or 4) end
      else
        local dbpm = math.floor(bpm + 0.5); if dbpm >= 100 then draw_digit(math.floor(dbpm/100), 6, 1) end
        draw_digit(math.floor((dbpm%100)/10), 10, 1); draw_digit(dbpm%10, 14, 1)
        increment_btns()
      end
      grid_led(1, 4, clock_source == 1 and 15 or 4); grid_led(1, 5, clock_source == 2 and 15 or 4)
    elseif pages.perform then
      for y = 1, #tracks do
        for x = 1, 8 do
          local p, has_s = presets[y][x], false
          if p then for i=1,32 do if (p.steps[i] or 0) > 0 then has_s = true; break end end end
          local br = (preset_blink[y].x == x) and (ratchet_blink_state and 15 or 0) or (active_preset[y] == x and 15 or (p and has_s and 6 or 2))
          grid_led(x, y, br)
        end
        grid_led(16, y, tracks[y].muted and 0 or 10)
        local isc = false; for _, trk in ipairs(cycle_held_order) do if trk == y then isc = true; break end end
        grid_led(10, y, isc and 15 or 4)
        for _, c in ipairs({12,13,14}) do grid_led(c, y, tracks[y].repeat_col == c and 15 or 4) end
      end
    elseif pages.swing then
      for i=1,#tracks do grid_led(1, i, (not selected_offset_track and i == selected_track) and 15 or 4); grid_led(2, i, i == selected_offset_track and 15 or 4) end
      if selected_offset_track then
        local mt = tracks[selected_offset_track].micro_timing
        if mt < 0 then draw_digit("-",6,1) elseif mt > 0 then draw_digit("+",6,1) end
        draw_digit(math.floor(math.abs(mt)/10), 10, 1); draw_digit(math.abs(mt)%10, 14, 1)
      else draw_digit(math.floor(tracks[selected_track].swing/10), 10, 1); draw_digit(tracks[selected_track].swing%10, 14, 1) end
      increment_btns()
    else
      local off = current_view_page() == 2 and 16 or 0
      for y = 1, #tracks do
        local sidx = tracks[y].pos
        if sidx == 0 then sidx = 1 end
        for x = 1, 16 do
          local idx, val = x + off, tracks[y].steps[x + off]
          local br = vel_led[val] or 0
          if val > 0 and tracks[y].ratchets[idx] then br = ratchet_blink_state and br or 1 end
          if idx == sidx then br = val > 0 and 15 or 12 end
          if pages.length and idx == tracks[y].length then br = (val == 0 and idx ~= sidx) and pulse_br or br end
          if pages.shift and (x == 1 or x == 16) then br = shift_pressed[y][x] and 15 or ((val == 0 and idx ~= sidx) and 2 or br) end
          grid_led(x, y, br)
        end
      end
  end
  grid_led(1, 8, playing and 15 or 4); grid_led(2, 8, 4); grid_led(3, 8, blink_state and 15 or (pages.bpm and 8 or 4))
  grid_led(7, 8, pages.length and pulse_br or 4) 
  local p_step = current_step == 0 and 1 or current_step; local ph_page = (any_track_over_16() and p_step > 16) and 2 or 1
  grid_led(5, 8, current_view_page() ~= 1 and 4 or (ph_page == 1 and 15 or 10)); grid_led(6, 8, current_view_page() ~= 2 and 4 or (ph_page == 2 and 15 or 10)) 
  grid_led(9, 8, vel_btn_held and 15 or (vel_led[default_velocity] or 0))
  grid_led(10, 8, ratchet_btn_held and 15 or (default_ratchet and (ratchet_blink_state and 15 or 4) or 4))
  grid_led(15, 8, pages.notes and 15 or 4); grid_led(16, 8, pages.perform and 15 or 4) 
  grid_led(13, 8, pages.shift and 15 or 4); grid_led(12, 8, pages.swing and 15 or 4)
  grid_refresh()
end
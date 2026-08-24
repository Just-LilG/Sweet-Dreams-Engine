/* Sweet Dreams WebUI — lavender/vanilla shell wired to cortex.
   Completes sweet-dreams-app-3.html against v2.5.39-skipmount. */

const MOD = '/data/adb/modules/sweet_dreams';
const CORTEX = `${MOD}/cortex`;
const GAUGE_C = 2 * Math.PI * 47;

const RENDER_LABELS = {
  default: ['Default', 'System-chosen, no override'],
  skiavk: ['SkiaVK', 'Best — Vulkan 1.3.177'],
  skiavkthreaded: ['SkiaVK (Threaded)', 'Vulkan + threaded backend'],
  skiagl: ['SkiaGL', 'Stable OpenGL fallback'],
  skiaglthreaded: ['SkiaGL (Threaded)', 'SkiaGL + threaded backend'],
  opengl: ['OpenGL ES', 'Legacy ES 3.2'],
  openglthreaded: ['OpenGL ES (Threaded)', 'Legacy ES + threaded backend'],
  vulkan: ['Vulkan', 'Same as SkiaVK — real mechanism, not a separate renderer'],
};

const SPOOF_DEVICES = [
  { id: 'off', name: 'Real Device', desc: 'No spoof — real device identity' },
  { id: 'legion', name: 'Lenovo Legion Y700 (2023)', desc: 'Triggers Legion gaming mode in CODM' },
  { id: 'redmagic', name: 'REDMAGIC 11 PRO', desc: 'Nubia flagship — unlocks 120 FPS' },
  { id: 'redmagic9', name: 'REDMAGIC 9 Pro', desc: 'ZTE/Nubia — alternative 120 FPS' },
  { id: 'rog', name: 'ASUS ROG Phone 6D Ultimate', desc: 'ROG Valhall profile + Vulkan opts' },
  { id: 'blackshark', name: 'Black Shark 4', desc: 'Shoulder trigger + 90 FPS profile' },
  { id: 'oneplus', name: 'OnePlus 13', desc: 'OPlus Game Space — smooth 90 FPS' },
  { id: 'samsung', name: 'Galaxy Z Fold 5', desc: 'Game Booster tier unlock' },
];

const CPU_PROFILES = [
  { key: 'sd8elite', name: 'Qualcomm Snapdragon 8 Elite' },
  { key: 'dimensity9400plus', name: 'MediaTek Dimensity 9400+' },
  { key: 'dimensity8350', name: 'MediaTek Dimensity 8350' },
  { key: '9000', name: 'HiSilicon Kirin 9000' },
  { key: '9000s', name: 'HiSilicon Kirin 9000S' },
  { key: '9020', name: 'HiSilicon Kirin 9020' },
  { key: '9020a', name: 'HiSilicon Kirin 9020A' },
  { key: '9030pro', name: 'HiSilicon Kirin 9030 Pro' },
  { key: '9030s', name: 'HiSilicon Kirin 9030S' },
  { key: 'xuanjie_o1', name: 'Xiaomi Xring O1' },
  { key: 'xuanjie_o3', name: 'Xiaomi Xring O3' },
];

let _toastTimer;
let _spoofPkg = '';
let _gamesAll = [];
let _gamesSelected = new Set();
let _dnsTimer;
let _touchTimer;
let _thermalSpoofTimer;

function sdHasBridge() {
  return typeof ksu !== 'undefined' && typeof ksu.exec === 'function';
}

function exec(command, timeoutMs = 20000) {
  return new Promise((resolve) => {
    if (!sdHasBridge()) {
      console.warn('[Bridge] mock:', command);
      resolve('');
      return;
    }
    let settled = false;
    const finish = (val) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      resolve(val == null ? '' : String(val));
    };
    const timeout = setTimeout(() => finish(''), timeoutMs);
    const handler = (errno, stdout) => {
      finish(errno === 0 || errno === undefined || errno === null ? (stdout || '') : '');
    };
    const cb = `exec_cb_${Date.now()}_${Math.random().toString(36).slice(2)}`;
    window[cb] = (errno, stdout, stderr) => {
      delete window[cb];
      handler(errno, stdout, stderr);
    };
    try {
      if (ksu.exec.length >= 3) {
        ksu.exec(command, {}, handler);
        return;
      }
      const maybe = ksu.exec(command, `window.${cb}`);
      if (maybe && typeof maybe.then === 'function') {
        maybe.then((result) => {
          const stdout = (result && result.stdout) || (typeof result === 'string' ? result : '');
          const errno = (result && result.errno) || 0;
          handler(errno, stdout);
        }).catch(() => finish(''));
      }
    } catch (e) {
      finish('');
    }
  });
}

async function se(cmd, fb = '', timeoutMs) {
  try {
    const out = (await exec(cmd, timeoutMs)).trim();
    return out === '' ? fb : out;
  } catch (e) {
    return fb;
  }
}

function shEsc(s) {
  return String(s).replace(/'/g, `'\\''`);
}

function persistFile(path) {
  return se(`sh "${CORTEX}/persist.sh" file '${shEsc(path)}'`);
}

function write(path, value) {
  return se(`mkdir -p "$(dirname '${shEsc(path)}')" && printf '%s\\n' '${shEsc(value)}' > '${shEsc(path)}'`).then(() => persistFile(path));
}

async function writeLines(path, lines) {
  if (!lines.length) {
    await se(`: > '${shEsc(path)}'`);
    return persistFile(path);
  }
  const body = lines.join('\n') + '\n';
  const b64 = btoa(unescape(encodeURIComponent(body)));
  await se(`echo '${b64}' | base64 -d > '${shEsc(path)}'`);
  return persistFile(path);
}

function apply(rel) {
  return se(`sh "${CORTEX}/${rel}"`);
}

function toast(msg) {
  const el = document.getElementById('sd-toast');
  if (!el) return;
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(_toastTimer);
  _toastTimer = setTimeout(() => el.classList.remove('show'), 2200);
}

function setOn(el, on) {
  if (!el) return;
  el.classList.toggle('on', !!on);
}

function isOn(el) {
  return !!(el && el.classList.contains('on'));
}

function sdPickChip(el) {
  const row = el.closest('.chip-row');
  if (!row) return;
  row.querySelectorAll('.chip').forEach((c) => c.classList.toggle('active', c === el));
}

function sdPickMode(el) {
  const container = el.parentElement;
  if (!container) return;
  container.querySelectorAll('.mode-card').forEach((c) => c.classList.toggle('active', c === el));
}

function setTheme(name) {
  document.documentElement.setAttribute('data-theme', name);
  try { localStorage.setItem('sd_theme', name); } catch (e) {}
  se(`mkdir -p "${CORTEX}/settings" && echo '${shEsc(name)}' > "${CORTEX}/settings/theme.txt"`);
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) {
    meta.setAttribute('content', getComputedStyle(document.documentElement).getPropertyValue('--theme-color-meta').trim());
  }
  document.querySelectorAll('.theme-card').forEach((c) => c.classList.remove('active'));
  document.getElementById('theme-card-' + name)?.classList.add('active');
}

window.setTheme = setTheme;
window.sdPickChip = sdPickChip;
window.sdPickMode = sdPickMode;

const PRIMARY_TABS = new Set(['home', 'games', 'logs']);

function showPanel(key) {
  document.querySelectorAll('.screen').forEach((s) => { s.style.display = 'none'; });
  const target = document.getElementById('panel-' + key);
  if (target) {
    target.style.display = '';
    const scroller = document.getElementById('app-scroll');
    if (scroller) scroller.scrollTop = 0;
    else window.scrollTo(0, 0);
  }
  const nav = document.getElementById('sd-bottom-nav');
  if (nav) nav.style.display = PRIMARY_TABS.has(key) ? '' : 'none';
  sdSyncBottomNav(key);
  const fab = document.getElementById('apply-fab');
  if (fab) fab.style.display = key === 'home' ? '' : 'none';
  loadPanel(key);
}

function shellNav(key, opts = {}) {
  const replace = opts.replace === true || PRIMARY_TABS.has(key);
  showPanel(key);
  try {
    if (replace) history.replaceState({ panel: key }, '', '#' + key);
    else history.pushState({ panel: key }, '', '#' + key);
  } catch (e) {}
}
window.shellNav = shellNav;

function shellBack() {
  // Prefer popping one history entry so the phone back stack stays clean.
  if (history.state && history.state.panel && history.state.panel !== 'home') {
    try { history.back(); return; } catch (e) {}
  }
  shellNav('home', { replace: true });
}
window.shellBack = shellBack;

function setBlurEnabled(on) {
  if (on) document.documentElement.removeAttribute('data-blur');
  else document.documentElement.setAttribute('data-blur', 'off');
  try { localStorage.setItem('sd_blur', on ? 'on' : 'off'); } catch (e) {}
  se(`mkdir -p "${CORTEX}/settings" && echo '${on ? 'on' : 'off'}' > "${CORTEX}/settings/blur.txt"`);
  setOn(document.getElementById('settings-tog-blur'), on);
}

function toggleBlur(el) {
  el.classList.toggle('on');
  setBlurEnabled(isOn(el));
  toast(isOn(el) ? 'Liquid glass on' : 'Solid colors on');
}
window.toggleBlur = toggleBlur;

function sdSyncBottomNav(key) {
  const tabMap = { home: 0, games: 1, logs: 2 };
  if (!(key in tabMap)) return;
  document.querySelectorAll('#sd-bottom-nav .nav-item').forEach((el, i) => {
    el.classList.toggle('active', i === tabMap[key]);
  });
}

function loadPanel(key) {
  if (typeof window._enginePoll === 'number') {
    clearInterval(window._enginePoll);
    window._enginePoll = null;
  }
  const loaders = {
    home: refreshHome,
    games: mod_games_load,
    logs: mod_logs_refresh,
    cpu: loadCpu,
    gpu: loadGpu,
    ram: loadRam,
    storage: loadStorage,
    battery: loadBattery,
    network: loadNet,
    killbg: loadKillBg,
    refresh: loadRefresh,
    renderscale: loadRes,
    animscale: loadAnim,
    touch: loadTouch,
    notify: loadNotify,
    audio: loadAudio,
    engine: loadEngine,
    health: loadHealth,
    compat: loadCompat,
    conflicts: loadConflicts,
    preloadlist: loadPreloadList,
    gamepreload: loadGamePreload,
    sensor: loadSensor,
    bypass: loadBypass,
    thermal: loadThermal,
    devicespoof: loadSpoof,
    settings: loadSettings,
  };
  const fn = loaders[key];
  if (fn) fn();
  if (key === 'engine') {
    window._enginePoll = setInterval(() => {
      const panel = document.getElementById('panel-engine');
      if (panel && panel.style.display !== 'none') loadEngine();
    }, 4000);
  }
}

function txt(id, value, cls) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = value;
  if (cls !== undefined) el.className = cls;
}

async function batched(cmds) {
  const M = '@SD@';
  const joined = cmds.map((c) => `${c}; echo "${M}"`).join('; ');
  const raw = await se(joined, '');
  const parts = raw.split(M).map((s) => s.trim());
  return cmds.map((_, i) => parts[i] || '');
}

async function refreshHome() {
  const rows = await batched([
    `getprop ro.product.model`,
    `getprop ro.build.version.release`,
    `cat /sys/class/power_supply/battery/temp 2>/dev/null`,
    `cat /sys/class/power_supply/battery/capacity 2>/dev/null`,
    `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null`,
    `cat "${CORTEX}/cpu/profile.txt" 2>/dev/null`,
    `(cat "${CORTEX}/thermal/armed.txt" 2>/dev/null; echo; cat "${CORTEX}/thermal/status.txt" 2>/dev/null)`,
    `cat "${CORTEX}/thermal/mode.txt" 2>/dev/null`,
    `cat "${CORTEX}/perf/enabled.txt" 2>/dev/null`,
    `cat "${CORTEX}/net/status.txt" 2>/dev/null`,
    `cat "${CORTEX}/net/congestion.txt" 2>/dev/null`,
    `cat "${CORTEX}/display/fps.txt" 2>/dev/null`,
    `cat "${CORTEX}/display/render.txt" 2>/dev/null`,
    `cat "${CORTEX}/display/resolution.txt" 2>/dev/null`,
    `cat "${CORTEX}/display/vsync.txt" 2>/dev/null`,
    `cat "${CORTEX}/display/anim_scale.txt" 2>/dev/null`,
    `cat "${CORTEX}/touch/status.txt" 2>/dev/null`,
    `cat "${CORTEX}/touch/report_rate.txt" 2>/dev/null`,
    `cat "${CORTEX}/battery/limit_enabled.txt" 2>/dev/null`,
    `cat "${CORTEX}/battery/limit_pct.txt" 2>/dev/null`,
    `cat "${CORTEX}/ram/mode.txt" 2>/dev/null`,
    `cat "${CORTEX}/ram/zram_enabled.txt" 2>/dev/null`,
    `cat "${CORTEX}/games/kill_bg_enabled.txt" 2>/dev/null`,
    `cat "${CORTEX}/audio/enabled.txt" 2>/dev/null`,
    `cat "${CORTEX}/notify/enabled.txt" 2>/dev/null`,
    `cat "${CORTEX}/ai/enabled.txt" 2>/dev/null`,
    `cat "${CORTEX}/ai/status.txt" 2>/dev/null`,
    `cat "${CORTEX}/games/spoof_master.txt" 2>/dev/null`,
    `cat "${CORTEX}/games/selected.txt" 2>/dev/null`,
    `cat "${CORTEX}/games/preload_enabled.txt" 2>/dev/null`,
    `cat "${CORTEX}/sensor/enabled.txt" 2>/dev/null`,
    `cat "${MOD}/module.prop" 2>/dev/null | grep '^version='`,
    `cat "${CORTEX}/daemons/last_game.txt" 2>/dev/null`,
    `df -k /data 2>/dev/null | tail -1`,
    `wc -l < "${CORTEX}/games/selected.txt" 2>/dev/null`,
  ]);

  const model = rows[0] || 'Unknown device';
  const android = rows[1] || '?';
  txt('home-device-sub', `${model} · Android ${android}`);

  const tempRaw = parseInt(rows[2], 10);
  const tempC = Number.isFinite(tempRaw) ? tempRaw / 10 : 0;
  txt('home-gauge-val', `${Math.round(tempC)}°`);
  let lbl = 'Cool';
  let offset = GAUGE_C * (1 - Math.min(tempC / 60, 1));
  const fill = document.getElementById('home-gauge-fill');
  if (tempC >= 47) { lbl = 'Hot'; if (fill) fill.style.stroke = 'var(--danger)'; }
  else if (tempC >= 42) { lbl = 'Warm'; if (fill) fill.style.stroke = 'var(--warn)'; }
  else { lbl = 'No Throttle'; if (fill) fill.style.stroke = 'var(--lavender)'; }
  txt('home-gauge-lbl', lbl);
  if (fill) fill.setAttribute('stroke-dashoffset', String(offset));

  txt('home-readout-batt', (rows[3] || '—') + '%');
  txt('home-readout-gov', rows[4] || '—');

  const profile = rows[5] || 'gaming';
  syncProfileUI(profile, false);
  txt('home-cpu-value', profile === 'gaming' ? 'Performance' : profile === 'battery' ? 'Efficiency' : 'Balanced');
  txt('home-sub-cpu', `Profile: ${profile}`);

  const render = rows[12] || 'skiavk';
  txt('home-gpu-value', (RENDER_LABELS[render] || [render])[0]);
  txt('home-sub-gpu', (RENDER_LABELS[render] || ['', render])[1] || render);
  txt('home-sub-render', (RENDER_LABELS[render] || [render])[0]);

  const netOn = rows[9] === 'on';
  const cc = rows[10] || 'bbr';
  txt('home-sub-net', netOn ? `${cc.toUpperCase()} + TCP fastopen` : 'Off', netOn ? 'row-desc ok' : 'row-desc');

  setOn(document.getElementById('home-tog-perf'), rows[8] === 'on');
  txt('home-sub-perf', rows[8] === 'on' ? 'On — MTK scenario API' : 'Off', rows[8] === 'on' ? 'row-desc ok' : 'row-desc');

  {
    const aiOn = rows[25] === 'on';
    const aiC = engineToken((rows[26] || '').split('|')[0]);
    txt('home-sub-engine', aiOn
      ? (aiC ? `Live · ${aiC}°C` : 'On')
      : (aiC ? `Idle · ${aiC}°C` : 'Off'));
  }
  txt('home-sub-ram', `${rows[21] === 'on' ? 'ZRAM' : 'No ZRAM'} · ${rows[20] || 'balanced'} mode`);
  txt('home-sub-fps', (rows[11] || '90') + ' Hz');
  const res = rows[13] || 'native';
  txt('home-sub-res', res === 'native' ? 'Native — Full' : Math.round(parseFloat(res) * 100) + '%');
  setOn(document.getElementById('home-tog-vsync'), rows[14] !== 'off');
  txt('home-sub-vsync', rows[14] === 'off' ? 'Off' : 'On', rows[14] === 'off' ? 'row-desc warn' : 'row-desc ok');
  txt('home-sub-anim', (rows[15] || '0.5') + 'x');
  setOn(document.getElementById('home-tog-touch'), rows[16] === 'on');
  txt('home-sub-touch', rows[16] === 'on' ? `Active — ${rows[17] || '240'}Hz` : 'Off', rows[16] === 'on' ? 'row-desc ok' : 'row-desc');
  txt('home-sub-battery', rows[18] === 'on' ? `On · stop at ${rows[19] || '80'}%` : 'Off');
  const df = rows[33] || '';
  const dfParts = df.trim().split(/\s+/);
  if (dfParts.length >= 4) {
    const usedPct = dfParts[4] || '—';
    const availKb = parseInt(dfParts[3], 10);
    const availGb = Number.isFinite(availKb) ? (availKb / 1024 / 1024).toFixed(1) : '—';
    txt('home-sub-storage', `${usedPct} used · ${availGb} GB free`);
  }
  txt('home-sub-killbg', rows[22] === 'on' ? 'On — kill on game launch' : 'Off');
  txt('home-sub-audio', rows[23] === 'on' ? 'On' : 'Off');
  txt('home-sub-notify', rows[24] === 'on' ? 'On' : 'Off');
  const nGames = (rows[28] || '').split(/\n/).filter(Boolean).length;
  txt('home-sub-games', nGames ? `${nGames} game${nGames === 1 ? '' : 's'} selected` : 'None selected');
  txt('home-sub-gamepreload', rows[29] === 'on' ? 'On' : 'Off');
  txt('home-sub-sensor', rows[30] === 'on' ? 'Armed' : 'Off');
  const sensorRow = document.getElementById('home-row-sensor');
  if (sensorRow) sensorRow.style.display = rows[30] === 'on' ? '' : 'none';
  const bypassNode = await se(`cat "${CORTEX}/battery/bypass_node.txt" 2>/dev/null`, '');
  txt('home-sub-bypass', bypassNode ? 'Node saved' : 'Scan required');

  const thermalArmed = /armed|disabled/.test(rows[6] || '');
  setOn(document.getElementById('home-tog-thermal'), thermalArmed);
  txt('home-sub-thermal', thermalArmed ? `Armed · ${rows[7] === 'extreme' ? 'Advanced' : 'Lite'}` : 'Off — real sensors');
  txt('home-sub-spoof', rows[27] === 'on' ? 'Active — Zygisk + prop hook' : 'Off');
  const pillT = document.getElementById('home-pill-thermal');
  if (pillT) pillT.textContent = thermalArmed ? 'Thermal armed' : 'Thermal off';
  const pillS = document.getElementById('home-pill-spoof');
  if (pillS) pillS.textContent = rows[27] === 'on' ? 'Spoof on' : 'Spoof off';
  const pillP = document.getElementById('home-pill-profile');
  if (pillP) pillP.textContent = 'Profile ' + (rows[5] || '—');

  const lastGame = rows[32];
  const banner = document.getElementById('home-game-status-banner');
  if (banner) {
    if (lastGame) {
      banner.style.display = 'flex';
      txt('home-game-status-name', lastGame.split('.').pop() + ' running');
      txt('home-game-status-sub', 'Boost active · OOM shield on');
    } else {
      banner.style.display = 'none';
    }
  }

  refreshHealthBanner();
  refreshConflictBanner();
}

function syncProfileUI(p, animate) {
  const grid = document.getElementById('home-profile-picker');
  if (!grid) return;
  const cards = Array.from(grid.children);
  const selected = cards.find((c) => c.dataset.profile === p);
  if (!selected) return;
  const others = cards.filter((c) => c !== selected);
  if (animate !== false) {
    const firstRects = new Map(cards.map((c) => [c, c.getBoundingClientRect()]));
    grid.innerHTML = '';
    if (others[0]) grid.appendChild(others[0]);
    grid.appendChild(selected);
    if (others[1]) grid.appendChild(others[1]);
    cards.forEach((c) => {
      const first = firstRects.get(c);
      if (!first) return;
      const last = c.getBoundingClientRect();
      const dx = first.left - last.left;
      if (dx !== 0) {
        c.style.transition = 'none';
        c.style.transform += ` translateX(${dx}px)`;
        requestAnimationFrame(() => {
          c.style.transition = '';
          c.style.transform = c.classList.contains('active') ? 'scale(1.08)' : 'scale(.96)';
        });
      }
    });
    selected.classList.remove('pop');
    void selected.offsetWidth;
    selected.classList.add('pop');
  }
  const balancedColor = getComputedStyle(document.documentElement).getPropertyValue('--lavender-pale').trim() || '#e6dcfb';
  const colors = { gaming: '#ffb39c', balanced: balancedColor, battery: '#a8ecc0' };
  const names = { gaming: 'Gaming', balanced: 'Balanced', battery: 'Battery' };
  Array.from(grid.children).forEach((c) => c.classList.toggle('active', c.dataset.profile === p));
  const val = document.getElementById('home-readout-profile-val');
  if (val) {
    val.style.color = colors[p] || balancedColor;
    val.textContent = names[p] || p;
  }
}

function mod_home_setProfile(p) {
  syncProfileUI(p, true);
  toast('Profile: ' + p);
  se(`sh "${CORTEX}/profile/apply.sh" '${p.replace(/'/g, '')}'`).then((out) => {
    toast(out.includes('PROFILE_APPLIED') ? 'CPU + GPU + sched applied' : 'Profile apply finished');
  });
  txt('home-cpu-value', p === 'gaming' ? 'Performance' : p === 'battery' ? 'Efficiency' : 'Balanced');
}
window.mod_home_setProfile = mod_home_setProfile;

function togglePerf(el) {
  el.classList.toggle('on');
  const next = isOn(el) ? 'on' : 'off';
  write(`${CORTEX}/perf/enabled.txt`, next);
  txt('home-sub-perf', next === 'on' ? 'On — MTK scenario API' : 'Off', next === 'on' ? 'row-desc ok' : 'row-desc');
  toast('PerfService: ' + next);
}
window.togglePerf = togglePerf;

function toggleVsync(el) {
  el.classList.toggle('on');
  const next = isOn(el) ? 'on' : 'off';
  write(`${CORTEX}/display/vsync.txt`, next).then(() => apply('display/apply.sh'));
  txt('home-sub-vsync', next === 'on' ? 'On' : 'Off', next === 'on' ? 'row-desc ok' : 'row-desc warn');
  toast('V-Sync: ' + next);
}
window.toggleVsync = toggleVsync;

function toggleTouch(el) {
  el.classList.toggle('on');
  const next = isOn(el) ? 'on' : 'off';
  write(`${CORTEX}/touch/status.txt`, next).then(() => apply('touch/apply.sh'));
  txt('home-sub-touch', next === 'on' ? 'Active' : 'Off');
  toast('Touch engine: ' + next);
}
window.toggleTouch = toggleTouch;

function toggleThermal(el) {
  el.classList.toggle('on');
  const armed = isOn(el);
  se(`. "${CORTEX}/thermal/state.sh"; thermal_set_armed ${armed ? 'armed' : 'off'}`);
  txt('home-sub-thermal', armed ? 'Armed — in-game only' : 'Off — real sensors');
  toast(armed ? 'Thermal spoof armed' : 'Thermal spoof off');
}
window.toggleThermal = toggleThermal;

async function applyAll() {
  const fab = document.getElementById('apply-fab');
  if (fab) fab.classList.add('applying');
  toast('Applying…');
  await se([
    `sh "${CORTEX}/thermal/kill_daemons_only.sh"`,
    `sh "${CORTEX}/cpu/apply.sh"`,
    `sh "${CORTEX}/gpu/apply.sh"`,
    `sh "${CORTEX}/touch/apply.sh"`,
    `sh "${CORTEX}/net/apply.sh"`,
    `sh "${CORTEX}/sched/apply.sh"`,
    `sh "${CORTEX}/display/apply.sh"`,
    `sh "${CORTEX}/ram/apply.sh"`,
    `sh "${CORTEX}/battery/apply.sh"`,
    `sh "${CORTEX}/games/build_spoof_json.sh"`,
    `sh "${CORTEX}/games/spoof.sh"`,
  ].join(' ; '), '', 45000);
  const fps = await se(`cat "${CORTEX}/display/fps.txt"`, '90');
  await se(`sh "${CORTEX}/fps/engine.sh" "${fps}" 2>/dev/null`);
  if (fab) fab.classList.remove('applying');
  toast('All tweaks applied');
  refreshHome();
}
window.applyAll = applyAll;

/* ── CPU ── */
async function loadCpu() {
  const [profile, a55, a76, govLive, lMin, lMax, lCur, bMin, bMax, bCur, abi] = await batched([
    `cat "${CORTEX}/cpu/profile.txt" 2>/dev/null`,
    `cat "${CORTEX}/cpu/a55_max_khz.txt" 2>/dev/null`,
    `cat "${CORTEX}/cpu/a76_max_khz.txt" 2>/dev/null`,
    `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null`,
    `cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null`,
    `cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null`,
    `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null`,
    `cat /sys/devices/system/cpu/cpu6/cpufreq/cpuinfo_min_freq 2>/dev/null || cat /sys/devices/system/cpu/cpu4/cpufreq/cpuinfo_min_freq 2>/dev/null`,
    `cat /sys/devices/system/cpu/cpu6/cpufreq/cpuinfo_max_freq 2>/dev/null || cat /sys/devices/system/cpu/cpu4/cpufreq/cpuinfo_max_freq 2>/dev/null`,
    `cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq 2>/dev/null || cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq 2>/dev/null`,
    `getprop ro.product.cpu.abi 2>/dev/null`,
  ]);
  const gov = profile === 'gaming' ? 'performance' : profile === 'battery' ? 'powersave' : 'schedutil';
  document.querySelectorAll('#cpu-profile-chips .chip').forEach((c) => c.classList.toggle('active', c.dataset.gov === gov));
  txt('cpu-active-gov', govLive || gov);
  const mhz = (v) => {
    const n = parseInt(v, 10);
    return Number.isFinite(n) && n > 0 ? (n / 1000).toFixed(0) : null;
  };
  const lMinM = mhz(lMin), lMaxM = mhz(lMax), lCurM = mhz(lCur);
  const bMinM = mhz(bMin), bMaxM = mhz(bMax), bCurM = mhz(bCur);
  txt('cpu-little-min', lMinM ? `Min ${lMinM} MHz` : 'Min —');
  txt('cpu-little-max', lMaxM ? `Max ${lMaxM} MHz` : 'Max —');
  txt('cpu-little-cur', lCurM ? `Current: ${lCurM} MHz` : 'Current: —');
  txt('cpu-big-min', bMinM ? `Min ${bMinM} MHz` : 'Min —');
  txt('cpu-big-max', bMaxM ? `Max ${bMaxM} MHz` : 'Max —');
  txt('cpu-big-cur', bCurM ? `Current: ${bCurM} MHz` : 'Current: —');
  const lBar = document.getElementById('cpu-little-bar');
  const bBar = document.getElementById('cpu-big-bar');
  if (lBar && lCurM && lMaxM) lBar.style.width = Math.min(100, Math.round((lCurM / lMaxM) * 100)) + '%';
  if (bBar && bCurM && bMaxM) bBar.style.width = Math.min(100, Math.round((bCurM / bMaxM) * 100)) + '%';
  const s0 = document.getElementById('cpu-policy0-max');
  const s1 = document.getElementById('cpu-policy1-max');
  if (s0) {
    if (lMaxM) { s0.max = String(lMaxM); s0.min = String(lMinM || 200); }
    s0.value = a55 ? String(Math.round(parseInt(a55, 10) / 1000)) : String(lMaxM || s0.value);
  }
  if (s1) {
    if (bMaxM) { s1.max = String(bMaxM); s1.min = String(bMinM || 400); }
    s1.value = a76 ? String(Math.round(parseInt(a76, 10) / 1000)) : String(bMaxM || s1.value);
  }
  txt('cpu-chip-sub', abi ? `${abi} · live cluster ceilings` : 'Live cluster ceilings');
}

document.addEventListener('click', (e) => {
  if (e.target.id === 'cpu-apply-btn' || e.target.closest?.('#cpu-apply-btn')) {
    e.preventDefault();
    applyCpu();
  }
});

async function applyCpu() {
  const chip = document.querySelector('#cpu-profile-chips .chip.active');
  const gov = chip ? chip.dataset.gov : 'performance';
  const profile = gov === 'performance' ? 'gaming' : gov === 'powersave' ? 'battery' : 'balanced';
  const a55 = parseInt(document.getElementById('cpu-policy0-max')?.value, 10);
  const a76 = parseInt(document.getElementById('cpu-policy1-max')?.value, 10);
  const btn = document.getElementById('cpu-apply-btn');
  if (btn) btn.textContent = 'Applying…';
  await write(`${CORTEX}/cpu/profile.txt`, profile);
  if (Number.isFinite(a55)) await write(`${CORTEX}/cpu/a55_max_khz.txt`, String(a55 * 1000));
  if (Number.isFinite(a76)) await write(`${CORTEX}/cpu/a76_max_khz.txt`, String(a76 * 1000));
  await apply('cpu/apply.sh');
  await apply('gpu/apply.sh');
  if (btn) { btn.textContent = 'Applied ✓'; setTimeout(() => { btn.textContent = 'Apply'; }, 1400); }
  toast('CPU profile: ' + profile);
}

async function resetCpu() {
  await se(`rm -f "${CORTEX}/cpu/a55_max_khz.txt" "${CORTEX}/cpu/a76_max_khz.txt"`);
  await write(`${CORTEX}/cpu/profile.txt`, 'balanced');
  await apply('cpu/apply.sh');
  await apply('gpu/apply.sh');
  const s0 = document.getElementById('cpu-policy0-max');
  const s1 = document.getElementById('cpu-policy1-max');
  if (s0) s0.value = '1800';
  if (s1) s1.value = '2200';
  await loadCpu();
  toast('CPU reset to balanced');
}
window.resetCpu = resetCpu;

/* ── GPU / render ── */
function mod_gpu_pickRender(el) {
  document.querySelectorAll('#gpu-render-select .select-option').forEach((o) => o.classList.remove('selected'));
  el.classList.add('selected');
  txt('gpu-render-selected-label', el.dataset.label);
  txt('gpu-render-selected-sub', el.dataset.sub);
  document.getElementById('gpu-render-select')?.classList.remove('open');
}
window.mod_gpu_pickRender = mod_gpu_pickRender;

async function loadGpu() {
  const [render, arch, vk, gov, cur, max] = await batched([
    `cat "${CORTEX}/display/render.txt" 2>/dev/null`,
    `getprop ro.hardware.egl 2>/dev/null; getprop ro.hardware.vulkan 2>/dev/null; getprop ro.hardware.gpu 2>/dev/null`,
    `getprop ro.opengles.version 2>/dev/null`,
    `cat /sys/class/misc/mali0/device/devfreq/mali0/governor 2>/dev/null || cat /sys/kernel/gpu/gpu_governor 2>/dev/null`,
    `cat /sys/class/misc/mali0/device/devfreq/mali0/cur_freq 2>/dev/null || cat /sys/kernel/gpu/gpu_cur_freq 2>/dev/null`,
    `cat /sys/class/misc/mali0/device/devfreq/mali0/max_freq 2>/dev/null || cat /sys/kernel/gpu/gpu_max_freq 2>/dev/null`,
  ]);
  const opt = document.querySelector(`#gpu-render-select .select-option[data-render="${render || 'skiavk'}"]`);
  if (opt) mod_gpu_pickRender(opt);
  const archName = (arch || '').split(/\n/).map((s) => s.trim()).filter(Boolean)[0] || 'Unknown GPU';
  txt('gpu-arch', archName);
  txt('gpu-chip-sub', archName);
  txt('gpu-vk', vk || '—');
  txt('gpu-gov', gov || '—');
  const curMhz = parseInt(cur, 10);
  const maxMhz = parseInt(max, 10);
  const curShow = Number.isFinite(curMhz) ? Math.round(curMhz / 1000000) : null;
  const maxShow = Number.isFinite(maxMhz) ? Math.round(maxMhz / 1000000) : null;
  txt('gpu-freq-lbl', curShow && maxShow ? `${curShow} MHz / ${maxShow} MHz max` : '—');
  const fill = document.getElementById('gpu-freq-fill');
  if (fill && curShow && maxShow && maxShow > 0) fill.style.width = Math.min(100, Math.round((curShow / maxShow) * 100)) + '%';
}

async function resetGpu() {
  await write(`${CORTEX}/display/render.txt`, 'skiavk');
  await apply('display/apply.sh');
  await loadGpu();
  toast('Render reset to SkiaVK');
}
window.resetGpu = resetGpu;

document.addEventListener('click', (e) => {
  if (e.target.id === 'gpu-apply-btn') {
    const selected = document.querySelector('#gpu-render-select .select-option.selected');
    const key = selected?.dataset.render || 'skiavk';
    const btn = e.target;
    btn.textContent = 'Applying…';
    write(`${CORTEX}/display/render.txt`, key).then(() => apply('display/apply.sh')).then(() => {
      btn.textContent = 'Applied ✓';
      setTimeout(() => { btn.textContent = 'Apply'; }, 1400);
      toast('Render: ' + key);
      txt('home-sub-render', (RENDER_LABELS[key] || [key])[0]);
    });
  }
});

/* ── RAM ── */
async function loadRam() {
  const [mode, size, mem, zram] = await batched([
    `cat "${CORTEX}/ram/mode.txt" 2>/dev/null`,
    `cat "${CORTEX}/ram/zram_size.txt" 2>/dev/null`,
    `awk '/MemTotal|MemAvailable/{print $2}' /proc/meminfo`,
    `awk '/SwapTotal|SwapFree/{print $2}' /proc/meminfo`,
  ]);
  const uiMode = mode === 'memory_saver' ? 'saver' : (mode || 'balanced');
  document.querySelectorAll('#panel-ram .mode-card').forEach((c) => c.classList.toggle('active', c.dataset.mode === uiMode));
  document.querySelectorAll('#ram-size-chips .chip').forEach((c) => c.classList.toggle('active', c.dataset.size === (size || '2')));
  const memParts = (mem || '').split(/\n/).map((n) => parseInt(n, 10)).filter(Number.isFinite);
  if (memParts.length >= 2) {
    const totalGb = memParts[0] / 1024 / 1024;
    const availGb = memParts[1] / 1024 / 1024;
    const usedGb = Math.max(0, totalGb - availGb);
    txt('ram-phys-txt', `${usedGb.toFixed(1)} / ${totalGb.toFixed(1)} GB`);
    const bar = document.getElementById('ram-phys-bar');
    if (bar && totalGb > 0) bar.style.width = Math.min(100, Math.round((usedGb / totalGb) * 100)) + '%';
  }
  const zParts = (zram || '').split(/\n/).map((n) => parseInt(n, 10)).filter(Number.isFinite);
  if (zParts.length >= 2 && zParts[0] > 0) {
    const totalMb = zParts[0] / 1024;
    const freeMb = zParts[1] / 1024;
    const usedMb = Math.max(0, totalMb - freeMb);
    txt('ram-zram-txt', `${Math.round(usedMb)} / ${Math.round(totalMb)} MB`);
    const zbar = document.getElementById('ram-zram-bar');
    if (zbar) zbar.style.width = Math.min(100, Math.round((usedMb / totalMb) * 100)) + '%';
  } else {
    txt('ram-zram-txt', 'Off');
    const zbar = document.getElementById('ram-zram-bar');
    if (zbar) zbar.style.width = '0%';
  }
}

document.addEventListener('click', (e) => {
  if (e.target.id === 'ram-apply-btn') {
    const modeCard = document.querySelector('#panel-ram .mode-card.active');
    const sizeChip = document.querySelector('#ram-size-chips .chip.active');
    const uiMode = modeCard?.dataset.mode || 'balanced';
    const mode = uiMode === 'saver' ? 'memory_saver' : uiMode;
    const size = sizeChip?.dataset.size || '2';
    const btn = e.target;
    btn.textContent = 'Applying…';
    se(`echo '${mode}' > "${CORTEX}/ram/mode.txt"; echo '${size}' > "${CORTEX}/ram/zram_size.txt"; sh "${CORTEX}/ram/apply.sh"`).then(() => {
      btn.textContent = 'Applied ✓';
      setTimeout(() => { btn.textContent = 'Apply RAM Settings'; }, 1600);
      toast('RAM: ' + mode + ' · ' + size + ' GB');
    });
  }
});

window.dropCaches = async () => {
  await se('sync; echo 3 > /proc/sys/vm/drop_caches');
  toast('Caches dropped');
};
window.trimApps = async () => {
  await se('cmd activity send-trim-memory 0 COMPLETE 2>/dev/null; am send-trim-memory 0 2>/dev/null');
  toast('Trim requested');
};

/* ── Storage ── */
async function loadStorage() {
  const df = await se('df -k /data 2>/dev/null | tail -1', '');
  const p = df.trim().split(/\s+/);
  if (p.length >= 4) {
    const total = (parseInt(p[1], 10) / 1024 / 1024).toFixed(1);
    const used = (parseInt(p[2], 10) / 1024 / 1024).toFixed(1);
    const avail = (parseInt(p[3], 10) / 1024 / 1024).toFixed(1);
    const pct = parseInt(p[4], 10) || 0;
    txt('storage-storage-txt', `${used} / ${total} GB`);
    txt('storage-free-badge', `${avail} GB free`);
    const bar = document.getElementById('storage-storage-bar');
    if (bar) bar.style.width = pct + '%';
    txt('home-sub-storage', `${p[4]} used · ${avail} GB free`);
  }
  const last = await se(`cat "${CORTEX}/storage/last_freed_kb.txt"`, '');
  if (last) {
    const kb = parseInt(last, 10);
    if (Number.isFinite(kb) && kb > 0) {
      const el = document.getElementById('storage-freed-amount');
      if (el) el.textContent = kb > 1024 * 1024 ? (kb / 1024 / 1024).toFixed(1) + ' GB' : Math.round(kb / 1024) + ' MB';
    }
  }
}

async function mod_storage_runCleanup() {
  const btn = document.getElementById('storage-clean-btn');
  const icon = document.getElementById('storage-clean-icon');
  const label = document.getElementById('storage-clean-label');
  if (btn?.classList.contains('busy')) return;
  btn?.classList.add('busy');
  if (label) label.textContent = 'Cleaning…';
  if (icon) {
    icon.classList.remove('broom');
    icon.classList.add('spin');
  }
  const before = await se(`df -k /data | tail -1 | awk '{print $4}'`, '0');
  await se(`sh "${CORTEX}/storage/clean.sh"`);
  const after = await se(`df -k /data | tail -1 | awk '{print $4}'`, before);
  const freedKb = Math.max(0, parseInt(after, 10) - parseInt(before, 10));
  await write(`${CORTEX}/storage/last_freed_kb.txt`, String(freedKb));
  const freed = document.getElementById('storage-freed-amount');
  if (freed) freed.textContent = freedKb > 1024 ? (freedKb / 1024).toFixed(1) + ' MB' : freedKb + ' KB';
  const when = document.getElementById('storage-freed-when');
  if (when) when.textContent = 'just now';
  btn?.classList.remove('busy');
  if (label) label.textContent = 'Clear App Caches';
  if (icon) {
    icon.classList.remove('spin');
    icon.classList.add('broom');
  }
  toast(freedKb > 0 ? `Freed ${Math.round(freedKb / 1024)} MB` : 'Cleanup finished');
  loadStorage();
}
window.mod_storage_runCleanup = mod_storage_runCleanup;

/* ── Battery ── */
function mod_battery_toggleBatt() {
  const t = document.getElementById('battery-tog-batt');
  t.classList.toggle('on');
  const cfg = document.getElementById('battery-batt-config');
  if (cfg) cfg.classList.toggle('open', isOn(t));
}
window.mod_battery_toggleBatt = mod_battery_toggleBatt;

function mod_battery_setLimit(el) {
  document.querySelectorAll('#battery-pct-chips .chip').forEach((c) => c.classList.remove('active'));
  el.classList.add('active');
  const info = {
    '60': 'Most conservative — maximizes long-term battery lifespan, shorter runtime per charge.',
    '70': 'A good balance for most people who charge overnight.',
    '80': 'Stopping at 80% is the sweet spot most manufacturers recommend for long-term battery health.',
    '90': 'Closer to a full charge with only a small lifespan trade-off.',
  };
  txt('battery-pct-info', info[el.dataset.pct] || '');
}
window.mod_battery_setLimit = mod_battery_setLimit;

async function loadBattery() {
  const [en, pct, cap] = await batched([
    `cat "${CORTEX}/battery/limit_enabled.txt" 2>/dev/null`,
    `cat "${CORTEX}/battery/limit_pct.txt" 2>/dev/null`,
    `cat /sys/class/power_supply/battery/capacity 2>/dev/null`,
  ]);
  setOn(document.getElementById('battery-tog-batt'), en === 'on');
  const cfg = document.getElementById('battery-batt-config');
  if (cfg) cfg.classList.toggle('open', en === 'on');
  document.querySelectorAll('#battery-pct-chips .chip').forEach((c) => c.classList.toggle('active', c.dataset.pct === (pct || '80')));
  const active = document.querySelector('#battery-pct-chips .chip.active');
  if (active) mod_battery_setLimit(active);
  txt('battery-batt-pct', (cap || '—') + '%');
}

document.addEventListener('click', (e) => {
  const btn = e.target.closest?.('#panel-battery .btn.primary');
  if (!btn) return;
  const en = isOn(document.getElementById('battery-tog-batt')) ? 'on' : 'off';
  const chip = document.querySelector('#battery-pct-chips .chip.active');
  const pct = chip?.dataset.pct || '80';
  btn.textContent = 'Applying…';
  se(`echo '${en}' > "${CORTEX}/battery/limit_enabled.txt"; echo '${pct}' > "${CORTEX}/battery/limit_pct.txt"; sh "${CORTEX}/battery/apply.sh"`).then(() => {
    btn.textContent = 'Applied ✓';
    setTimeout(() => { btn.textContent = 'Apply Battery Settings'; }, 1400);
    toast(en === 'on' ? `Charge limit ${pct}%` : 'Charge limit off');
  });
});

/* ── Network ── */
const CC_INFO = {
  bbr: "Google's algorithm — models the actual network path instead of reacting to packet loss.",
  westwood: 'Loss-based estimator that copes better with wireless packet loss than Cubic.',
  cubic: 'Android default. Fine for most connections; not the lowest-latency pick.',
  reno: 'Legacy TCP. Only useful as a last-resort fallback.',
};

function toggleNet(el) {
  el.classList.toggle('on');
}
window.toggleNet = toggleNet;

function mod_network_setCC(el) {
  sdPickChip(el);
  txt('network-cc-info', CC_INFO[el.dataset.cc] || '');
}
window.mod_network_setCC = mod_network_setCC;

function mod_network_setDns(el) {
  sdPickChip(el);
  const cfg = document.getElementById('network-dns-config');
  if (cfg) cfg.style.display = el.dataset.dns === 'off' ? 'none' : 'block';
}
window.mod_network_setDns = mod_network_setDns;

function mod_network_setDnsPreset(el) {
  const [d1, d2] = (el.dataset.preset || '').split('|');
  const i1 = document.getElementById('network-dns1');
  const i2 = document.getElementById('network-dns2');
  if (i1 && d1) i1.value = d1;
  if (i2 && d2) i2.value = d2;
  document.querySelectorAll('#network-dns-config .chip[data-preset]').forEach((c) => c.classList.toggle('active', c === el));
}
window.mod_network_setDnsPreset = mod_network_setDnsPreset;

function togglePingStab(el) {
  if (!el) el = document.getElementById('network-tog-pingstab');
  el.classList.toggle('on');
  const on = isOn(el);
  write(`${CORTEX}/net/ping_stabilizer_enabled.txt`, on ? 'on' : 'off');
  txt('network-ping-status', on ? 'Armed — applies when a selected game launches.' : 'Not active — enable above, then launch a game.');
}
window.togglePingStab = togglePingStab;

async function loadNet() {
  const [st, cc, dns, d1, d2, ping] = await batched([
    `cat "${CORTEX}/net/status.txt" 2>/dev/null`,
    `cat "${CORTEX}/net/congestion.txt" 2>/dev/null`,
    `cat "${CORTEX}/net/dns_mode.txt" 2>/dev/null`,
    `cat "${CORTEX}/net/dns1.txt" 2>/dev/null`,
    `cat "${CORTEX}/net/dns2.txt" 2>/dev/null`,
    `cat "${CORTEX}/net/ping_stabilizer_enabled.txt" 2>/dev/null`,
  ]);
  setOn(document.getElementById('network-tog-net'), st === 'on');
  document.querySelectorAll('#network-cc-chips .chip').forEach((c) => c.classList.toggle('active', c.dataset.cc === (cc || 'bbr')));
  txt('network-cc-info', CC_INFO[cc] || CC_INFO.bbr);
  const dnsChip = document.querySelector(`#network-dns-chips .chip[data-dns="${dns || 'off'}"]`);
  if (dnsChip) mod_network_setDns(dnsChip);
  const i1 = document.getElementById('network-dns1');
  const i2 = document.getElementById('network-dns2');
  if (i1) i1.value = d1 || '1.1.1.1';
  if (i2) i2.value = d2 || '1.0.0.1';
  setOn(document.getElementById('network-tog-pingstab'), ping === 'on');
  txt('network-live-cc', (cc || 'bbr').toUpperCase());
}

document.addEventListener('click', (e) => {
  const btn = e.target.closest?.('#panel-network .btn.primary');
  if (!btn) return;
  const on = isOn(document.getElementById('network-tog-net')) ? 'on' : 'off';
  const cc = document.querySelector('#network-cc-chips .chip.active')?.dataset.cc || 'bbr';
  const dns = document.querySelector('#network-dns-chips .chip.active')?.dataset.dns || 'off';
  const d1 = document.getElementById('network-dns1')?.value || '1.1.1.1';
  const d2 = document.getElementById('network-dns2')?.value || '1.0.0.1';
  btn.textContent = 'Applying…';
  se(`echo '${on}' > "${CORTEX}/net/status.txt"; echo '${cc}' > "${CORTEX}/net/congestion.txt"; echo '${dns}' > "${CORTEX}/net/dns_mode.txt"; echo '${shEsc(d1)}' > "${CORTEX}/net/dns1.txt"; echo '${shEsc(d2)}' > "${CORTEX}/net/dns2.txt"; sh "${CORTEX}/net/apply.sh"`).then(() => {
    btn.textContent = 'Applied ✓';
    setTimeout(() => { btn.textContent = 'Apply Network Settings'; }, 1600);
    toast('Network: ' + cc);
    txt('network-live-cc', cc.toUpperCase());
  });
});

/* ── Kill BG ── */
function mod_killbg_toggleKill() {
  const t = document.getElementById('killbg-tog-killbg');
  const turningOn = !isOn(t);
  if (turningOn && !confirm('Kill background apps on game launch? Other apps will be force-stopped (system apps are spared).')) return;
  t.classList.toggle('on');
  write(`${CORTEX}/games/kill_bg_enabled.txt`, isOn(t) ? 'on' : 'off');
  toast('Kill BG: ' + (isOn(t) ? 'on' : 'off'));
}
window.mod_killbg_toggleKill = mod_killbg_toggleKill;

async function loadKillBg() {
  const en = await se(`cat "${CORTEX}/games/kill_bg_enabled.txt"`, 'off');
  setOn(document.getElementById('killbg-tog-killbg'), en === 'on');
  const last = await se(`cat "${CORTEX}/games/kill_bg_last.txt" 2>/dev/null`, '');
  const box = document.getElementById('killbg-kill-status');
  if (box) {
    if (!last) {
      box.textContent = 'No launch report yet — runs when a selected game starts.';
      box.classList.remove('active');
    } else {
      const [pkg, killed] = last.split('|');
      box.textContent = `${(pkg || 'game').split('.').pop()} launched · ${killed || '0'} apps stopped`;
      box.classList.add('active');
    }
  }
  const logBox = document.getElementById('killbg-log-box');
  if (logBox) {
    const log = await se(`grep KILL_BG "${MOD}/boot.log" 2>/dev/null | tail -8`, '');
    const lines = log.split(/\n/).filter(Boolean);
    logBox.innerHTML = lines.length
      ? lines.map((l) => `<div class="log-entry"><span class="log-app">${l.replace(/</g, '')}</span></div>`).join('')
      : '<div class="log-entry" style="color:rgba(255,255,255,.4);font-size:11px;border:none;">No session yet</div>';
  }
}

/* ── Refresh / FPS ── */
function lockFile(mode) {
  return mode === 'always' ? 'locked' : mode;
}
function lockUi(file) {
  return file === 'locked' ? 'always' : (file || 'off');
}

function mod_refresh_setFPS(el, hz) {
  document.querySelectorAll('#refresh-fps-chips .chip').forEach((c) => c.classList.remove('active'));
  el.classList.add('active');
  txt('refresh-rr-live-hz', hz + ' Hz');
  write(`${CORTEX}/display/fps.txt`, String(hz)).then(() => se(`sh "${CORTEX}/fps/engine.sh" "${hz}" 2>/dev/null`));
  txt('home-sub-fps', hz + ' Hz');
  toast('Refresh: ' + hz + 'Hz');
}
window.mod_refresh_setFPS = mod_refresh_setFPS;

function mod_refresh_setLock(el, mode) {
  document.querySelectorAll('#panel-refresh .lock-card').forEach((c) => c.classList.remove('active'));
  el.classList.add('active');
  const file = lockFile(mode);
  write(`${CORTEX}/display/rr_lock.txt`, file).then(() => apply('display/apply.sh'));
  txt('refresh-rr-live-status', mode === 'always' ? 'Hard Lock' : mode === 'game' ? 'Game Lock' : 'Free');
  toast('RR lock: ' + mode);
}
window.mod_refresh_setLock = mod_refresh_setLock;

function mod_refresh_setFPSLock(el, val) {
  document.querySelectorAll('#refresh-fpslk-chips .chip').forEach((c) => c.classList.remove('active'));
  el.classList.add('active');
  write(`${CORTEX}/display/fps_lock_game.txt`, val);
  const badge = document.getElementById('refresh-fpslk-badge');
  const info = document.getElementById('refresh-fpslk-info');
  if (val === 'off') {
    if (badge) badge.textContent = 'OFF';
    if (info) info.style.display = 'none';
  } else {
    if (badge) badge.textContent = val + ' FPS';
    if (info) info.style.display = 'block';
    txt('refresh-fpslk-info-txt', `Capping at ${val} FPS in-game. Re-applied every 2s.`);
  }
  toast('FPS lock: ' + val);
}
window.mod_refresh_setFPSLock = mod_refresh_setFPSLock;

async function loadRefresh() {
  const [fps, lock, fpslk] = await batched([
    `cat "${CORTEX}/display/fps.txt" 2>/dev/null`,
    `cat "${CORTEX}/display/rr_lock.txt" 2>/dev/null`,
    `cat "${CORTEX}/display/fps_lock_game.txt" 2>/dev/null`,
  ]);
  document.querySelectorAll('#refresh-fps-chips .chip').forEach((c) => c.classList.toggle('active', c.dataset.fps === (fps || '90')));
  txt('refresh-rr-live-hz', (fps || '90') + ' Hz');
  const ui = lockUi(lock);
  document.querySelectorAll('#panel-refresh .lock-card').forEach((c) => c.classList.toggle('active', c.dataset.mode === ui));
  document.querySelectorAll('#refresh-fpslk-chips .chip').forEach((c) => c.classList.toggle('active', c.dataset.fpslk === (fpslk || 'off')));
}

/* ── Render scale ── */
function mod_renderscale_pickRes(el) {
  document.querySelectorAll('#panel-renderscale .res-card').forEach((c) => {
    c.classList.remove('active');
    c.querySelector('.badge-active')?.remove();
  });
  el.classList.add('active');
  const name = el.querySelector('.res-name');
  if (name && !name.querySelector('.badge-active')) {
    const badge = document.createElement('span');
    badge.className = 'badge-active';
    badge.textContent = 'ACTIVE';
    name.appendChild(badge);
  }
  const res = el.dataset.res;
  write(`${CORTEX}/display/resolution.txt`, res);
  txt('home-sub-res', res === 'native' ? 'Native — Full' : Math.round(parseFloat(res) * 100) + '%');
  se(`sh "${CORTEX}/display/apply_selected.sh" '${res}'`).then((out) => {
    if (String(out || '').includes('NO_GAMES')) {
      toast('Add games on the Games tab — scale applies to those packages');
    } else {
      toast('Render scale: ' + (res === 'native' ? 'Native' : Math.round(parseFloat(res) * 100) + '%') + ' — reopen the game if it is already open');
    }
  });
}
window.mod_renderscale_pickRes = mod_renderscale_pickRes;

async function loadRes() {
  const res = await se(`cat "${CORTEX}/display/resolution.txt"`, 'native');
  const card = document.querySelector(`#panel-renderscale .res-card[data-res="${res}"]`);
  if (card) {
    document.querySelectorAll('#panel-renderscale .res-card').forEach((c) => {
      c.classList.remove('active');
      c.querySelector('.badge-active')?.remove();
    });
    card.classList.add('active');
  }
}

/* ── Anim ── */
function mod_animscale_pick(el) {
  document.querySelectorAll('#animscale-anim-chips .chip').forEach((c) => c.classList.remove('active'));
  el.classList.add('active');
  const val = el.dataset.anim;
  write(`${CORTEX}/display/anim_scale.txt`, val);
  se(`settings put global window_animation_scale ${val}; settings put global transition_animation_scale ${val}; settings put global animator_duration_scale ${val}`);
  txt('home-sub-anim', val + 'x');
  toast('Anim: ' + val + 'x');
}
window.mod_animscale_pick = mod_animscale_pick;

async function loadAnim() {
  const val = await se(`cat "${CORTEX}/display/anim_scale.txt"`, '0.5');
  document.querySelectorAll('#animscale-anim-chips .chip').forEach((c) => c.classList.toggle('active', c.dataset.anim === val));
}

/* ── Touch ── */
function mod_touch_pick(el, group) {
  const id = group.startsWith('touch-') ? group : 'touch-' + group;
  document.querySelectorAll('#' + id + ' .chip').forEach((c) => c.classList.remove('active'));
  el.classList.add('active');
}
window.mod_touch_pick = mod_touch_pick;

function toggleInputBooster(el) {
  el.classList.toggle('on');
  write(`${CORTEX}/touch/input_booster.txt`, isOn(el) ? 'on' : 'off').then(() => apply('touch/apply.sh'));
}
window.toggleInputBooster = toggleInputBooster;

function toggleNoiseFilter(el) {
  el.classList.toggle('on');
  write(`${CORTEX}/touch/noise_filter.txt`, isOn(el) ? 'on' : 'off').then(() => apply('touch/apply.sh'));
}
window.toggleNoiseFilter = toggleNoiseFilter;

function debounceTouchWrite() {
  clearTimeout(_touchTimer);
  _touchTimer = setTimeout(() => {
    const swipe = document.getElementById('touch-sl-swipe')?.value || '8';
    const lp = document.getElementById('touch-sl-lp')?.value || '400';
    se(`echo '${swipe}' > "${CORTEX}/touch/swipe_px.txt"; echo '${lp}' > "${CORTEX}/touch/lp_timeout.txt"; sh "${CORTEX}/touch/apply.sh"`);
  }, 250);
}

async function loadTouch() {
  const [st, ib, nf, rr, ts, swipe, lp] = await batched([
    `cat "${CORTEX}/touch/status.txt" 2>/dev/null`,
    `cat "${CORTEX}/touch/input_booster.txt" 2>/dev/null`,
    `cat "${CORTEX}/touch/noise_filter.txt" 2>/dev/null`,
    `cat "${CORTEX}/touch/report_rate.txt" 2>/dev/null`,
    `cat "${CORTEX}/touch/tap_sens.txt" 2>/dev/null`,
    `cat "${CORTEX}/touch/swipe_px.txt" 2>/dev/null`,
    `cat "${CORTEX}/touch/lp_timeout.txt" 2>/dev/null`,
  ]);
  setOn(document.getElementById('touch-tog-ib'), ib !== 'off');
  setOn(document.getElementById('touch-tog-nf'), nf === 'on');
  document.querySelectorAll('#touch-rr-chips .chip').forEach((c) => c.classList.toggle('active', c.dataset.rr === (rr || '240')));
  document.querySelectorAll('#touch-ts-chips .chip').forEach((c) => c.classList.toggle('active', c.dataset.ts === (ts || 'medium')));
  const sEl = document.getElementById('touch-sl-swipe');
  const lEl = document.getElementById('touch-sl-lp');
  if (sEl) sEl.value = swipe || '8';
  if (lEl) lEl.value = lp || '400';
  void st;
}

document.addEventListener('input', (e) => {
  if (e.target.id === 'touch-sl-swipe' || e.target.id === 'touch-sl-lp') debounceTouchWrite();
});

document.addEventListener('click', (e) => {
  if (e.target.id !== 'touch-apply-btn') return;
  const rr = document.querySelector('#touch-rr-chips .chip.active')?.dataset.rr || '240';
  const ts = document.querySelector('#touch-ts-chips .chip.active')?.dataset.ts || 'medium';
  const btn = e.target;
  btn.textContent = 'Applying…';
  se(`echo '${rr}' > "${CORTEX}/touch/report_rate.txt"; echo '${ts}' > "${CORTEX}/touch/tap_sens.txt"; sh "${CORTEX}/touch/apply.sh"`).then(() => {
    btn.textContent = 'Applied ✓';
    setTimeout(() => { btn.textContent = 'Apply Touch Settings'; }, 1600);
    toast('Touch: ' + rr + ' Hz');
  });
});

/* ── Notify ── */
function mod_notify_toggleMaster() {
  const master = document.getElementById('notify-tog-master');
  master.classList.toggle('on');
  const on = isOn(master);
  const cats = document.getElementById('notify-categories');
  if (cats) {
    cats.style.opacity = on ? '1' : '.4';
    cats.style.pointerEvents = on ? 'auto' : 'none';
  }
  write(`${CORTEX}/notify/enabled.txt`, on ? 'on' : 'off');
}
window.mod_notify_toggleMaster = mod_notify_toggleMaster;

function toggleNotifyCat(el) {
  el.classList.toggle('on');
  const file = el.dataset.file;
  if (file) write(`${CORTEX}/notify/${file}.txt`, isOn(el) ? 'on' : 'off');
}
window.toggleNotifyCat = toggleNotifyCat;

async function loadNotify() {
  const [master, launch, exit, thermal, spoof] = await batched([
    `cat "${CORTEX}/notify/enabled.txt" 2>/dev/null`,
    `cat "${CORTEX}/notify/game_launch.txt" 2>/dev/null`,
    `cat "${CORTEX}/notify/game_exit.txt" 2>/dev/null`,
    `cat "${CORTEX}/notify/thermal_override.txt" 2>/dev/null`,
    `cat "${CORTEX}/notify/spoof_active.txt" 2>/dev/null`,
  ]);
  setOn(document.getElementById('notify-tog-master'), master !== 'off');
  const map = { game_launch: launch, game_exit: exit, thermal_override: thermal, spoof_active: spoof };
  document.querySelectorAll('#notify-categories .cat-tog').forEach((el) => {
    setOn(el, map[el.dataset.file] !== 'off');
  });
}

/* ── Audio ── */
function toggleAudioLatency(el) {
  el.classList.toggle('on');
  const on = isOn(el);
  write(`${CORTEX}/audio/enabled.txt`, on ? 'on' : 'off');
  txt('audio-live-state', on || isOn(document.getElementById('audio-tog-bt')) ? 'Armed' : 'Off');
  txt('home-sub-audio', on ? 'On — in-game props' : 'Off');
  toast('Audio latency: ' + (on ? 'on' : 'off'));
}
window.toggleAudioLatency = toggleAudioLatency;

function toggleBtLowLatency(el) {
  el.classList.toggle('on');
  write(`${CORTEX}/audio/bt_lowlat.txt`, isOn(el) ? 'on' : 'off');
  toast('BT low-latency: ' + (isOn(el) ? 'on' : 'off'));
}
window.toggleBtLowLatency = toggleBtLowLatency;

async function loadAudio() {
  const [en, bt, verify] = await batched([
    `cat "${CORTEX}/audio/enabled.txt" 2>/dev/null`,
    `cat "${CORTEX}/audio/bt_lowlat.txt" 2>/dev/null`,
    `cat "${CORTEX}/audio/verify.txt" 2>/dev/null`,
  ]);
  setOn(document.getElementById('audio-tog-lat'), en === 'on');
  setOn(document.getElementById('audio-tog-bt'), bt === 'on');
  txt('audio-live-state', en === 'on' ? 'Armed' : 'Off');
  const rows = document.getElementById('audio-verify-rows');
  const [ok, total] = (verify || '0|4').split('|');
  const labels = [
    'audio.deep_buffer.media = false',
    'vendor.audio.mmap.enable = true',
    'persist.vendor.audio.lowlatency.enable = true',
    'af.fast_track_multiplier = 1',
  ];
  if (rows) {
    rows.innerHTML = labels.map((lab, i) => {
      const stuck = parseInt(ok, 10) > i;
      return `<div class="stat-row"><span class="stat-label">${lab}</span><span class="stat-val" style="color:var(--${stuck ? 'ok' : 'warn'})">${stuck ? 'ok' : '—'}</span></div>`;
    }).join('');
  }
  txt('audio-verify-summary', verify ? `${ok}/${total || '4'} props confirmed stuck after last game launch` : 'No verify yet — launches a game after enabling to populate this.');
}

/* ── Engine ── */
function engineToken(v) {
  const s = String(v || '').trim();
  if (!s || s === 'off' || s === 'idle' || s === '-') return '';
  return s;
}

function engineTempLabel(statusC, sysTenths) {
  const c = engineToken(statusC);
  if (c && !Number.isNaN(Number(c))) return c + '°C';
  const t = parseInt(String(sysTenths || '').trim(), 10);
  if (!Number.isNaN(t) && t > 0) return (t / 10).toFixed(1) + '°C';
  return '—';
}

function mod_engine_toggleEngine() {
  const t = document.getElementById('engine-tog-eng');
  t.classList.toggle('on');
  const on = isOn(t);
  write(`${CORTEX}/ai/enabled.txt`, on ? 'on' : 'off');
  if (on) {
    se(`pgrep -f 'cortex/ai/engine.sh' >/dev/null || nohup sh "${CORTEX}/ai/engine.sh" >> "${MOD}/boot.log" 2>&1 &`, '');
  }
  toast('Engine: ' + (on ? 'on' : 'off'));
  setTimeout(loadEngine, 600);
}
window.mod_engine_toggleEngine = mod_engine_toggleEngine;

async function loadEngine() {
  const [en, st, ov, sched, night, morn, low, log, sysTemp, sysCap, sysRam, sysGov, sysProf] = await batched([
    `cat "${CORTEX}/ai/enabled.txt" 2>/dev/null`,
    `cat "${CORTEX}/ai/status.txt" 2>/dev/null`,
    `cat "${CORTEX}/ai/override_active.txt" 2>/dev/null`,
    `cat "${CORTEX}/ai/schedule_enabled.txt" 2>/dev/null`,
    `cat "${CORTEX}/ai/schedule_night_hour.txt" 2>/dev/null`,
    `cat "${CORTEX}/ai/schedule_morning_hour.txt" 2>/dev/null`,
    `cat "${CORTEX}/ai/schedule_low_bat_pct.txt" 2>/dev/null`,
    `tail -n 8 "${MOD}/boot.log" 2>/dev/null | grep '\\[AI\\]'`,
    `cat /sys/class/power_supply/battery/temp 2>/dev/null`,
    `cat /sys/class/power_supply/battery/capacity 2>/dev/null`,
    `awk '/MemAvailable/ {print int($2/1024); exit}' /proc/meminfo 2>/dev/null`,
    `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null`,
    `cat "${CORTEX}/cpu/profile.txt" 2>/dev/null`,
  ]);
  setOn(document.getElementById('engine-tog-eng'), en === 'on');
  setOn(document.getElementById('engine-tog-sched'), sched === 'on');
  const nh = document.getElementById('engine-night-h');
  const mh = document.getElementById('engine-morning-h');
  const lb = document.getElementById('engine-low-bat');
  if (nh && document.activeElement !== nh) nh.value = night || '23';
  if (mh && document.activeElement !== mh) mh.value = morn || '7';
  if (lb && document.activeElement !== lb) lb.value = low || '15';
  const p = (st || '').split('|');
  const temp = engineTempLabel(p[0], sysTemp);
  const batt = engineToken(p[1]) || (sysCap && sysCap.trim()) || '';
  const ram = engineToken(p[2]) || (sysRam && sysRam.trim()) || '';
  const gov = engineToken(p[3]) || (sysGov && sysGov.trim()) || '';
  const prof = engineToken(p[4]) || (sysProf && sysProf.trim()) || '';
  txt('engine-stat-temp', temp);
  txt('engine-stat-batt', batt ? batt + '%' : '—');
  txt('engine-stat-ram', ram ? ram + ' MB' : '—');
  txt('engine-stat-gov', gov || '—');
  txt('engine-stat-profile', prof || '—');
  txt('engine-eng-temp', temp);
  const banner = document.getElementById('engine-override-banner');
  if (banner) banner.style.display = ov === 'on' ? 'block' : 'none';
  const logEl = document.getElementById('engine-last-log');
  if (logEl) logEl.textContent = log || 'No engine log yet.';
}

function mod_engine_toggleSched() {
  const t = document.getElementById('engine-tog-sched');
  t.classList.toggle('on');
  write(`${CORTEX}/ai/schedule_enabled.txt`, isOn(t) ? 'on' : 'off');
}
window.mod_engine_toggleSched = mod_engine_toggleSched;

function mod_engine_saveSched() {
  const night = document.getElementById('engine-night-h')?.value || '23';
  const morn = document.getElementById('engine-morning-h')?.value || '7';
  const low = document.getElementById('engine-low-bat')?.value || '15';
  write(`${CORTEX}/ai/schedule_night_hour.txt`, night);
  write(`${CORTEX}/ai/schedule_morning_hour.txt`, morn);
  write(`${CORTEX}/ai/schedule_low_bat_pct.txt`, low);
}
window.mod_engine_saveSched = mod_engine_saveSched;

function mod_engine_applyNow() {
  se(`sh "${CORTEX}/cpu/apply.sh"; sh "${CORTEX}/gpu/apply.sh"`);
  toast('Engine profile applied');
}
window.mod_engine_applyNow = mod_engine_applyNow;

function mod_engine_restart() {
  se(`pkill -f "${CORTEX}/ai/engine.sh"; sleep 1; nohup sh "${CORTEX}/ai/engine.sh" >> "${MOD}/boot.log" 2>&1 &`);
  toast('Engine restarted');
  setTimeout(loadEngine, 1600);
}
window.mod_engine_restart = mod_engine_restart;

/* ── Thermal ── */
function thermalEngineMode(ui) {
  return ui === 'lite' ? 'lite' : 'extreme';
}

function thermalShowMode(ui) {
  document.querySelectorAll('#thermal-mode-chips .chip').forEach((c) => c.classList.toggle('active', c.dataset.mode === ui));
  const lite = document.getElementById('thermal-lite-info');
  const adv = document.getElementById('thermal-advanced-info');
  const ext = document.getElementById('thermal-extreme-info');
  const spoof = document.getElementById('thermal-spoof-block');
  if (lite) lite.style.display = ui === 'lite' ? 'block' : 'none';
  if (adv) adv.style.display = ui === 'advanced' ? 'block' : 'none';
  if (ext) ext.style.display = ui === 'extreme' ? 'block' : 'none';
  if (spoof) spoof.style.display = ui === 'lite' ? 'none' : 'block';
}

function mod_thermal_toggleThermal() {
  const t = document.getElementById('thermal-tog-th');
  t.classList.toggle('on');
  const armed = isOn(t);
  const ui = document.querySelector('#thermal-mode-chips .chip.active')?.dataset.mode || 'lite';
  se(`. "${CORTEX}/thermal/state.sh"; thermal_set_armed ${armed ? 'armed' : 'off'}`).then(() => persistFile(`${CORTEX}/thermal/armed.txt`));
  txt('thermal-th-state', armed ? 'Armed' : 'Off');
  const el = document.getElementById('thermal-th-state');
  if (el) el.style.color = armed ? 'var(--ok)' : 'var(--danger)';
  txt('home-sub-thermal', armed ? `Armed · ${ui}` : 'Off — real sensors');
  if (armed) {
    se(`sh "${CORTEX}/thermal/apply.sh" game_start ${thermalEngineMode(ui)}`);
  } else {
    se(`sh "${CORTEX}/thermal/apply.sh" game_end`);
  }
}
window.mod_thermal_toggleThermal = mod_thermal_toggleThermal;

function mod_thermal_pickMode(el) {
  const ui = el.dataset.mode || 'lite';
  if (ui === 'advanced' && !confirm('Advanced spoofs battery and extra sensors. Android may not see real overheating. Continue?')) return;
  if (ui === 'extreme' && !confirm('Extreme spoofs every temp sensor and applies immediately when armed. Continue?')) return;
  thermalShowMode(ui);
  write(`${CORTEX}/thermal/mode.txt`, ui === 'lite' ? 'lite' : 'extreme');
  write(`${CORTEX}/thermal/ui_mode.txt`, ui);
  const armed = isOn(document.getElementById('thermal-tog-th'));
  if (armed && ui !== 'lite') {
    se(`sh "${CORTEX}/thermal/apply.sh" game_start extreme`);
  }
}
window.mod_thermal_pickMode = mod_thermal_pickMode;

function thermalSpoofLabel(c) {
  const n = Number(c);
  if (!Number.isFinite(n)) return '—';
  if (n <= 0) return '0°C — report sensors as freezing';
  return `${n}°C — OS / games see this`;
}

function mod_thermal_onSpoofInput(el) {
  const c = Math.max(0, Math.min(45, parseInt(el.value, 10) || 0));
  txt('thermal-spoof-c-val', thermalSpoofLabel(c));
  clearTimeout(_thermalSpoofTimer);
  _thermalSpoofTimer = setTimeout(() => {
    write(`${CORTEX}/thermal/spoof_c.txt`, String(c)).then(() => {
      const armed = isOn(document.getElementById('thermal-tog-th'));
      const ui = document.querySelector('#thermal-mode-chips .chip.active')?.dataset.mode || 'lite';
      if (armed) {
        se(`sh "${CORTEX}/thermal/apply.sh" game_start ${thermalEngineMode(ui)}`);
      }
    });
  }, 250);
}
window.mod_thermal_onSpoofInput = mod_thermal_onSpoofInput;

async function loadThermal() {
  const [armedFile, st, mode, temp, spoof, z0, verify] = await batched([
    `cat "${CORTEX}/thermal/armed.txt" 2>/dev/null`,
    `cat "${CORTEX}/thermal/status.txt" 2>/dev/null`,
    `cat "${CORTEX}/thermal/mode.txt" 2>/dev/null`,
    `cat /sys/class/power_supply/battery/temp 2>/dev/null`,
    `cat "${CORTEX}/thermal/spoof_c.txt" 2>/dev/null`,
    `cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null`,
    `cat "${CORTEX}/thermal/last_verify.txt" 2>/dev/null`,
  ]);
  const armed = armedFile === 'armed' || st === 'disabled';
  setOn(document.getElementById('thermal-tog-th'), armed);
  txt('thermal-th-state', armed ? 'Armed' : 'Off');
  const uiFile = (await se(`cat "${CORTEX}/thermal/ui_mode.txt" 2>/dev/null`, '')).trim();
  const ui = uiFile || (mode === 'extreme' ? 'advanced' : 'lite');
  thermalShowMode(ui);
  const tRaw = parseInt(temp, 10);
  if (Number.isFinite(tRaw)) txt('thermal-real-temp', (tRaw / 10).toFixed(1) + '°C');
  const zRaw = parseInt(z0, 10);
  const osEl = document.getElementById('thermal-os-temp');
  if (osEl) osEl.textContent = Number.isFinite(zRaw) ? (zRaw / 1000).toFixed(1) + '°C OS-seen' : '—';
  const verEl = document.getElementById('thermal-verify-box');
  if (verEl) verEl.textContent = verify ? ('Last apply: ' + verify) : 'No spoof verify yet — launches a game (or apply) to populate this.';
  let c = parseInt(spoof, 10);
  if (!Number.isFinite(c)) c = 27;
  c = Math.max(0, Math.min(45, c));
  const sl = document.getElementById('thermal-spoof-c');
  if (sl) sl.value = String(c);
  txt('thermal-spoof-c-val', thermalSpoofLabel(c));
}

/* ── Spoof ── */
function mod_devicespoof_toggleMaster() {
  const t = document.getElementById('devicespoof-tog-master');
  t.classList.toggle('on');
  const on = isOn(t);
  txt('devicespoof-spoof-state', on ? 'Active' : 'Off');
  const cfg = document.getElementById('devicespoof-config-section');
  if (cfg) {
    cfg.style.opacity = on ? '1' : '.4';
    cfg.style.pointerEvents = on ? 'auto' : 'none';
  }
  if (on && !confirm('Device spoof changes identity seen by games. Competitive titles may flag this. Continue?')) {
    t.classList.remove('on');
    return;
  }
  write(`${CORTEX}/games/spoof_master.txt`, on ? 'on' : 'off').then(() => {
    if (on) {
      se(`sh "${CORTEX}/games/build_spoof_json.sh"; sh "${CORTEX}/games/spoof.sh"; if ! pgrep -f "${MOD}/controller" >/dev/null; then nohup "${MOD}/controller" >/dev/null 2>&1 & fi`);
    } else {
      se(`pkill -f "${MOD}/controller" 2>/dev/null; sh "${CORTEX}/games/spoof.sh"`);
    }
  });
  toast('Spoof: ' + (on ? 'on' : 'off'));
}
window.mod_devicespoof_toggleMaster = mod_devicespoof_toggleMaster;

function parseSpoofLine(line) {
  const [left, device] = line.split('|');
  if (!left) return null;
  const [pkg, ...tags] = left.split(':');
  const cpuTag = tags.find((t) => t.startsWith('cpu=') || t === 'with_cpu');
  return {
    pkg: pkg.trim(),
    device: (device || 'off').trim(),
    cpu: !!cpuTag,
    cpuKey: cpuTag && cpuTag.startsWith('cpu=') ? cpuTag.slice(4) : 'sd8elite',
  };
}

function renderSpoofDetails(deviceId) {
  const d = SPOOF_DEVICES.find((x) => x.id === deviceId);
  const box = document.getElementById('devicespoof-device-details');
  if (!box) return;
  if (!d || d.id === 'off') {
    box.innerHTML = '<div style="font-size:11px;color:rgba(255,255,255,.6);line-height:1.6;">No spoof — this game keeps its real device identity.</div>';
    return;
  }
  box.innerHTML = `<div style="font-size:12px;font-weight:700;margin-bottom:4px;">${d.name}</div><div style="font-size:11px;color:rgba(255,255,255,.6);line-height:1.6;">${d.desc}</div>`;
}

function applySpoofRowToUi(row) {
  const sel = document.getElementById('devicespoof-device-select');
  const cpuTog = document.getElementById('devicespoof-tog-cpu');
  const cpuSel = document.getElementById('devicespoof-cpu-select');
  const picker = document.getElementById('devicespoof-cpu-picker');
  if (sel) sel.value = row?.device || 'off';
  setOn(cpuTog, !!(row && row.cpu));
  if (cpuSel && row?.cpuKey) cpuSel.value = row.cpuKey;
  if (picker) picker.style.display = row && row.cpu ? 'block' : 'none';
  renderSpoofDetails(row?.device || 'off');
}

function mod_devicespoof_pickGame(el) {
  document.querySelectorAll('#devicespoof-game-chips .chip').forEach((c) => c.classList.remove('active'));
  el.classList.add('active');
  _spoofPkg = el.dataset.pkg || '';
  txt('devicespoof-selected-game-name', el.textContent.trim());
  se(`cat "${CORTEX}/games/spoof_assignments.txt" 2>/dev/null`, '').then((raw) => {
    const row = raw.split(/\n/).map(parseSpoofLine).find((r) => r && r.pkg === _spoofPkg);
    applySpoofRowToUi(row);
  });
}
window.mod_devicespoof_pickGame = mod_devicespoof_pickGame;

function mod_devicespoof_toggleCpu() {
  const t = document.getElementById('devicespoof-tog-cpu');
  t.classList.toggle('on');
  const picker = document.getElementById('devicespoof-cpu-picker');
  if (picker) picker.style.display = isOn(t) ? 'block' : 'none';
  if (!_spoofPkg) return;
  saveSpoofAssignment();
}
window.mod_devicespoof_toggleCpu = mod_devicespoof_toggleCpu;

async function loadSpoof() {
  const [master, selected, assigns] = await batched([
    `cat "${CORTEX}/games/spoof_master.txt" 2>/dev/null`,
    `cat "${CORTEX}/games/selected.txt" 2>/dev/null`,
    `cat "${CORTEX}/games/spoof_assignments.txt" 2>/dev/null`,
  ]);
  const on = master === 'on';
  setOn(document.getElementById('devicespoof-tog-master'), on);
  txt('devicespoof-spoof-state', on ? 'Active' : 'Off');
  const stateEl = document.getElementById('devicespoof-spoof-state');
  if (stateEl) stateEl.style.color = on ? 'var(--ok)' : 'var(--danger)';
  const cfg = document.getElementById('devicespoof-config-section');
  if (cfg) {
    cfg.style.opacity = on ? '1' : '.4';
    cfg.style.pointerEvents = on ? 'auto' : 'none';
  }
  const chips = document.getElementById('devicespoof-game-chips');
  const pkgs = (selected || '').split(/\n/).map((s) => s.trim()).filter(Boolean);
  if (chips) {
    chips.innerHTML = pkgs.length
      ? pkgs.map((pkg, i) => `<div class="chip${i === 0 ? ' active' : ''}" data-pkg="${pkg}" onclick="mod_devicespoof_pickGame(this)">${pkg.split('.').pop()}</div>`).join('')
      : '<div class="chip">No games selected</div>';
    if (pkgs[0]) {
      _spoofPkg = pkgs[0];
      txt('devicespoof-selected-game-name', pkgs[0].split('.').pop());
    }
  }
  const sel = document.getElementById('devicespoof-device-select');
  if (sel && !sel.dataset.wired) {
    sel.innerHTML = SPOOF_DEVICES.map((d) => `<option value="${d.id}">${d.name}</option>`).join('');
    sel.dataset.wired = '1';
    sel.addEventListener('change', saveSpoofAssignment);
  }
  const cpuSel = document.getElementById('devicespoof-cpu-select');
  if (cpuSel && !cpuSel.dataset.wired) {
    cpuSel.innerHTML = CPU_PROFILES.map((p) => `<option value="${p.key}">${p.name}</option>`).join('');
    cpuSel.dataset.wired = '1';
    cpuSel.addEventListener('change', saveSpoofAssignment);
  }
  const rows = (assigns || '').split(/\n/).map(parseSpoofLine).filter(Boolean);
  const cur = rows.find((r) => r.pkg === _spoofPkg);
  applySpoofRowToUi(cur);
}

async function saveSpoofAssignment() {
  if (!_spoofPkg) return;
  const deviceId = document.getElementById('devicespoof-device-select')?.value || 'off';
  const cpuOn = isOn(document.getElementById('devicespoof-tog-cpu'));
  const cpuKey = document.getElementById('devicespoof-cpu-select')?.value || 'sd8elite';
  const raw = await se(`cat "${CORTEX}/games/spoof_assignments.txt" 2>/dev/null`, '');
  const lines = raw.split(/\n/).filter((l) => {
    const linePkg = l.split(/[:|]/)[0];
    return l.trim() && linePkg !== _spoofPkg;
  });
  if (deviceId !== 'off') {
    const tag = cpuOn ? `:cpu=${cpuKey}` : '';
    lines.push(_spoofPkg + tag + '|' + deviceId);
  } else if (cpuOn) {
    lines.push(_spoofPkg + `:cpu=${cpuKey}|off`);
  }
  await writeLines(`${CORTEX}/games/spoof_assignments.txt`, lines);
  renderSpoofDetails(deviceId);
  se(`sh "${CORTEX}/games/build_spoof_json.sh"; sh "${CORTEX}/games/spoof.sh"; pkill -f "${MOD}/controller" 2>/dev/null; sleep 1; nohup "${MOD}/controller" >/dev/null 2>&1 &`);
  toast(deviceId === 'off' ? 'Spoof removed' : `${_spoofPkg.split('.').pop()} → ${deviceId}`);
}

/* ── Games ── */

let _gameLabels = {};

function gameLabel(pkg) {
  return _gameLabels[pkg] || pkg.split('.').pop();
}

function gameAvatarHtml(pkg) {
  return `<div class="game-icon" data-pkg="${pkg}"><svg viewBox="0 0 24 24" fill="none" stroke-width="2"><rect x="2" y="6" width="20" height="12" rx="6"/></svg></div>`;
}

async function fillGameIcons(pkgs) {
  for (const pkg of pkgs.slice(0, 24)) {
    const raw = await se(`sh "${CORTEX}/games/get_icon.sh" '${pkg.replace(/'/g, "")}' 2>/dev/null`, '');
    if (!raw || raw.length < 24) continue;
    let mime = 'image/png';
    let b64 = raw.trim();
    const pipe = raw.indexOf('|');
    if (pipe > 0 && pipe < 20) {
      mime = raw.slice(0, pipe).trim();
      b64 = raw.slice(pipe + 1).trim();
    }
    if (b64.length < 32) continue;
    document.querySelectorAll(`.game-icon[data-pkg="${pkg}"]`).forEach((el) => {
      el.innerHTML = `<img alt="" src="data:${mime};base64,${b64}">`;
    });
  }
}

async function mod_games_load() {
  const statusEl = document.getElementById('games-scan-status');
  const listEl = document.getElementById('games-installed-list');
  if (!sdHasBridge()) {
    if (statusEl) statusEl.textContent = 'No root bridge — open this from KernelSU / MMRL to scan apps.';
    return;
  }
  if (statusEl) statusEl.textContent = 'Loading games…';
  await se(`sh "${CORTEX}/games/list_apps.sh" prune`);
  const sel = await se(`cat "${CORTEX}/games/selected.txt" 2>/dev/null`, '');
  _gamesSelected = new Set(sel.split(/\n/).map((s) => s.trim()).filter(Boolean));
  const pkgs = Array.from(_gamesSelected);
  if (pkgs.length) {
    const labeled = await se(`sh "${CORTEX}/games/list_apps.sh" labels ${pkgs.map((p) => `'${p.replace(/'/g, "")}'`).join(' ')}`, '');
    labeled.split(/\n/).forEach((line) => {
      const i = line.indexOf('|');
      if (i > 0) _gameLabels[line.slice(0, i)] = line.slice(i + 1);
    });
  }
  const likely = await se(`sh "${CORTEX}/games/list_apps.sh" likely`, '');
  likely.split(/\n/).forEach((line) => {
    const i = line.indexOf('|');
    if (i > 0) _gameLabels[line.slice(0, i)] = line.slice(i + 1);
  });
  if (statusEl) statusEl.textContent = '';
  mod_games_renderSelected();
  fillGameIcons(pkgs);
}
window.mod_games_load = mod_games_load;

function mod_games_renderSelected() {
  const listEl = document.getElementById('games-installed-list');
  if (!listEl) return;
  if (_gamesSelected.size === 0) {
    listEl.innerHTML = '<div class="empty-state">No games selected yet — search by name below. Random user apps stay out of this list until you add them.</div>';
    return;
  }
  listEl.innerHTML = Array.from(_gamesSelected).map((pkg) => {
    const spoofPath = `${CORTEX}/games/${pkg}.spoof_c`;
    return `<div class="game-row">
      ${gameAvatarHtml(pkg)}
      <div class="game-meta" style="flex:1;min-width:0;">
        <div class="game-name">${gameLabel(pkg)}</div>
        <div class="game-pkg" style="font-size:10px;color:rgba(255,255,255,.45);overflow:hidden;text-overflow:ellipsis;">${pkg}</div>
        <label style="font-size:10px;color:rgba(255,255,255,.5);">Spoof °C <input type="number" min="0" max="45" placeholder="default" style="width:64px;margin-left:6px;background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.16);color:#fff;border-radius:8px;padding:2px 6px;" onchange="mod_games_setSpoofC('${pkg}', this.value)"></label>
      </div>
      <div class="game-actions">
        <button type="button" onclick="event.stopPropagation();mod_games_launch('${pkg}')">Launch</button>
        <button type="button" onclick="event.stopPropagation();mod_games_stop('${pkg}')">Stop</button>
      </div>
      <div class="switch on" onclick="mod_games_toggle('${pkg}', this)"></div>
    </div>`;
  }).join('');
}

function mod_games_setSpoofC(pkg, val) {
  const n = parseInt(val, 10);
  if (!Number.isFinite(n) || val === '') {
    se(`rm -f "${CORTEX}/games/${pkg}.spoof_c"`);
    return;
  }
  write(`${CORTEX}/games/${pkg}.spoof_c`, String(Math.max(0, Math.min(45, n))));
}
window.mod_games_setSpoofC = mod_games_setSpoofC;

async function mod_games_filterPicker(query) {
  const resultsEl = document.getElementById('games-search-results');
  if (!resultsEl) return;
  if (!query || query.length < 2) { resultsEl.innerHTML = ''; return; }
  const raw = await se(`sh "${CORTEX}/games/list_apps.sh" search '${query.replace(/'/g, "")}'`, '');
  const rows = raw.split(/\n/).map((line) => {
    const i = line.indexOf('|');
    if (i < 0) return null;
    const pkg = line.slice(0, i);
    const lab = line.slice(i + 1);
    _gameLabels[pkg] = lab;
    return pkg;
  }).filter(Boolean).slice(0, 20);
  resultsEl.innerHTML = rows.length
    ? rows.map((pkg) => {
        const on = _gamesSelected.has(pkg);
        return `<div class="game-row">${gameAvatarHtml(pkg)}<div class="game-meta" style="flex:1;"><div class="game-name">${gameLabel(pkg)}</div><div style="font-size:10px;color:rgba(255,255,255,.45);">${pkg}</div></div><div class="switch${on ? ' on' : ''}" onclick="mod_games_toggle('${pkg}', this)"></div></div>`;
      }).join('')
    : '<div class="empty-state">No matching apps</div>';
  fillGameIcons(rows);
}
window.mod_games_filterPicker = mod_games_filterPicker;

async function mod_games_toggle(pkg, el) {
  el.classList.toggle('on');
  if (el.classList.contains('on')) _gamesSelected.add(pkg);
  else _gamesSelected.delete(pkg);
  await writeLines(`${CORTEX}/games/selected.txt`, Array.from(_gamesSelected));
  mod_games_renderSelected();
  fillGameIcons(Array.from(_gamesSelected));
}
window.mod_games_toggle = mod_games_toggle;

function mod_games_launch(pkg) {
  toast('Launching…');
  se(`sh "${CORTEX}/games/control.sh" launch '${pkg.replace(/'/g, "")}'`);
}
window.mod_games_launch = mod_games_launch;

function mod_games_stop(pkg) {
  se(`sh "${CORTEX}/games/control.sh" stop '${pkg.replace(/'/g, "")}'`);
  toast('Force-stopped');
}
window.mod_games_stop = mod_games_stop;

function mod_games_stopAll() {
  se(`sh "${CORTEX}/games/control.sh" stop_all`);
  toast('Stopped selected games');
}
window.mod_games_stopAll = mod_games_stopAll;

/* ── Logs ── */
async function mod_logs_refresh() {
  const termEl = document.getElementById('logs-term');
  if (!sdHasBridge()) {
    if (termEl) termEl.textContent = 'No root bridge — open this from the installed module to see live logs.';
    return;
  }
  if (termEl) termEl.textContent = 'Loading…';
  const src = document.querySelector('#logs-source-chips .chip.active')?.dataset.src || 'boot';
  const file = src === 'session' ? `${CORTEX}/daemons/session.log`
    : src === 'thermal' ? `${CORTEX}/thermal/last_verify.txt`
    : `${MOD}/boot.log`;
  const [ai, mon, ctrl, log] = await batched([
    `pgrep -f "${CORTEX}/ai/engine.sh" 2>/dev/null`,
    `pgrep -f "${CORTEX}/daemons/game_monitor.sh" 2>/dev/null`,
    `pgrep -f "${MOD}/controller" 2>/dev/null`,
    `tail -n 120 "${file}" 2>/dev/null`,
  ]);
  txt('logs-batt-status', ai ? 'Running' : 'Not detected');
  txt('logs-games-status', mon ? 'Running' : 'Not detected — may need reboot');
  txt('logs-bypass-status', ctrl ? 'Controller running' : 'Controller idle');
  document.getElementById('logs-batt-status')?.classList.toggle('ok', !!ai);
  document.getElementById('logs-games-status')?.classList.toggle('ok', !!mon);
  if (termEl) termEl.textContent = log || `(${src} log empty)`;
}
function mod_logs_pickSource(el) {
  document.querySelectorAll('#logs-source-chips .chip').forEach((c) => c.classList.remove('active'));
  el.classList.add('active');
  mod_logs_refresh();
}
window.mod_logs_pickSource = mod_logs_pickSource;

window.mod_logs_refresh = mod_logs_refresh;

async function mod_logs_copy() {
  const text = document.getElementById('logs-term')?.textContent || '';
  try { await navigator.clipboard.writeText(text); toast('Copied'); }
  catch (e) { toast('Clipboard unavailable'); }
}
window.mod_logs_copy = mod_logs_copy;

async function mod_logs_clear() {
  await se(`: > "${MOD}/boot.log"`);
  txt('logs-term', '(cleared)');
}
window.mod_logs_clear = mod_logs_clear;

async function mod_logs_restart() {
  toast('Restarting daemons…');
  await se(`
OLD_AI=$(cat "${MOD}/run/ai_engine.pid" 2>/dev/null)
[ -n "$OLD_AI" ] && kill "$OLD_AI" 2>/dev/null
pkill -f "${CORTEX}/ai/engine.sh" 2>/dev/null
mkdir -p "${MOD}/run"
sleep 1
nohup sh "${CORTEX}/ai/engine.sh" >> "${MOD}/boot.log" 2>&1 &
OLD=$(cat "${MOD}/run/game_monitor.pid" 2>/dev/null)
[ -n "$OLD" ] && kill "$OLD" 2>/dev/null
sleep 1
nohup sh "${CORTEX}/daemons/game_monitor.sh" >> "${MOD}/boot.log" 2>&1 &
SPOOF_ON=$(cat "${CORTEX}/games/spoof_master.txt" 2>/dev/null || echo off)
if [ "$SPOOF_ON" = "on" ]; then
  pkill -f "${MOD}/controller" 2>/dev/null
  sleep 1
  nohup "${MOD}/controller" >/dev/null 2>&1 &
fi
echo "[$(date '+%H:%M:%S')] Daemons restarted from WebUI" >> "${MOD}/boot.log"
`, '', 20000);
  toast('Daemons restarted');
  setTimeout(() => mod_logs_refresh(), 1500);
}
window.mod_logs_restart = mod_logs_restart;

/* ── Health / compat / conflicts ── */
function rowHtml(title, sub, tag, ok) {
  return `<div class="row"><div><div style="font-size:13px;font-weight:700;">${title}</div>${sub ? `<div style="font-size:11px;color:rgba(255,255,255,.55);margin-top:2px;">${sub}</div>` : ''}</div><span class="tag ${ok ? 'ok' : 'warn'}">${tag}</span></div>`;
}

async function loadHealth() {
  const list = document.getElementById('health-list');
  if (!list) return;
  const raw = await se(`for f in "${CORTEX}"/health/*.status; do [ -f "$f" ] || continue; echo "##$(basename "$f" .status)"; cat "$f"; echo; done`, '');
  if (!raw.trim()) {
    list.innerHTML = '<div class="row"><div style="font-size:13px;font-weight:700;">No health report yet</div><span class="tag ok">OK</span></div>';
    return;
  }
  const html = [];
  let sub = '';
  raw.split(/\n/).forEach((line) => {
    if (line.startsWith('##')) { sub = line.slice(2); return; }
    if (!line.trim()) return;
    const parts = line.split('|');
    const name = parts[1] || line;
    const ok = parts[2] === '1';
    const detail = parts[3] || '';
    html.push(rowHtml((sub ? sub + ' · ' : '') + name, detail, ok ? 'OK' : 'Failed', ok));
  });
  list.innerHTML = html.join('') || '<div class="row"><div style="font-size:13px;font-weight:700;">No health report yet</div><span class="tag ok">OK</span></div>';
}

async function refreshHealthBanner() {
  const raw = await se(`cat "${CORTEX}"/health/*.status 2>/dev/null`, '');
  const fails = raw.split(/\n/).filter((l) => {
    const p = l.split('|');
    return p.length >= 3 && p[2] === '0';
  }).length;
  const banner = document.getElementById('home-health-banner');
  if (!banner) return;
  if (fails > 0) {
    banner.style.display = 'flex';
    txt('home-health-title', `${fails} optimization${fails === 1 ? '' : 's'} failed to apply`);
  } else banner.style.display = 'none';
}

async function loadCompat() {
  const list = document.getElementById('compat-list');
  if (!list) return;
  const raw = await se(`cat "${CORTEX}/device/capabilities.txt" 2>/dev/null; sh "${CORTEX}/device/capability_probe.sh" 2>/dev/null | tail -20`, '');
  const homeRow = document.getElementById('home-row-compat');
  if (!raw) {
    if (homeRow) homeRow.style.display = 'none';
    list.innerHTML = '<div class="row"><div style="font-size:13px;font-weight:700;">No probe results yet</div><span class="tag warn">Hidden on Home until probed</span></div>';
    txt('home-sub-compat', '—');
    return;
  }
  if (homeRow) homeRow.style.display = '';

  const lines = raw.split(/\n/).filter(Boolean).slice(-12);
  list.innerHTML = lines.map((line) => {
    const ok = /yes|ok|supported|1$/i.test(line);
    return rowHtml(line.replace(/=/g, ': '), '', ok ? 'Supported' : 'Not exposed', ok);
  }).join('');
  txt('home-sub-compat', 'Probed');
}

async function loadConflicts() {
  const list = document.getElementById('conflicts-list');
  if (!list) return;
  const raw = await se(`sh "${CORTEX}/device/check_conflicts.sh" 2>/dev/null`, '');
  const lines = raw.split(/\n/).filter((l) => l.trim() && !/^\[/.test(l));
  if (!lines.length) {
    list.innerHTML = '<div class="row"><div style="font-size:13px;font-weight:700;">No overlapping modules found</div><span class="tag ok">Clear</span></div>';
    return;
  }
  list.innerHTML = lines.map((line) => rowHtml(line, '', 'Conflict', false)).join('');
}

async function refreshConflictBanner() {
  const raw = await se(`ls /data/adb/modules 2>/dev/null`, '');
  const others = raw.split(/\n/).map((s) => s.trim()).filter((s) => s && s !== 'sweet_dreams' && s !== 'zygisksu' && s !== 'zygisk_lsposed');
  const banner = document.getElementById('home-conflict-banner');
  if (!banner) return;
  const tuning = others.filter((n) => /perf|thermal|game|fps|kernel|magisk|fdeai|azenith|frieren/i.test(n));
  if (tuning.length) {
    banner.style.display = 'flex';
    txt('home-conflict-title', `${tuning.length} other tuning module${tuning.length === 1 ? '' : 's'} detected`);
  } else banner.style.display = 'none';
}

async function loadPreloadList() {
  const list = document.getElementById('preload-list');
  if (!list) return;
  const raw = await se(`ls "${CORTEX}/games/profiles" 2>/dev/null`, '');
  const files = raw.split(/\n/).filter((f) => f.endsWith('.txt'));
  const homeRow = document.getElementById('home-row-preload');
  if (!files.length) {
    if (homeRow) homeRow.style.display = 'none';
    list.innerHTML = '<div class="row"><div style="font-size:13px;font-weight:700;">No seeded profiles yet</div></div>';
    txt('home-sub-preload', '—');
    return;
  }
  if (homeRow) homeRow.style.display = '';

  list.innerHTML = files.slice(0, 40).map((f) => {
    const pkg = f.replace(/\.txt$/, '').replace(/-/g, '.');
    return `<div class="row"><div style="font-size:13px;font-weight:700;">${pkg}</div><span style="font-size:11px;color:var(--lavender-pale);">profile</span></div>`;
  }).join('');
  txt('home-sub-preload', `${files.length} games ready`);
}

function toggleGamePreload(el) {
  el.classList.toggle('on');
  write(`${CORTEX}/games/preload_enabled.txt`, isOn(el) ? 'on' : 'off');
  toast('Game preload: ' + (isOn(el) ? 'on' : 'off'));
}
window.toggleGamePreload = toggleGamePreload;

function mod_gamepreload_setBudget(el) {
  document.querySelectorAll('#gamepreload-budget-chips .chip').forEach((c) => c.classList.remove('active'));
  el.classList.add('active');
  write(`${CORTEX}/games/preload_budget_mb.txt`, el.dataset.mb || '500');
}
window.mod_gamepreload_setBudget = mod_gamepreload_setBudget;

async function loadGamePreload() {
  const [en, budget] = await batched([
    `cat "${CORTEX}/games/preload_enabled.txt" 2>/dev/null`,
    `cat "${CORTEX}/games/preload_budget_mb.txt" 2>/dev/null`,
  ]);
  setOn(document.getElementById('gamepreload-tog-preload'), en === 'on');
  document.querySelectorAll('#gamepreload-budget-chips .chip').forEach((c) => c.classList.toggle('active', c.dataset.mb === (budget || '500')));
}

function mod_sensor_toggleSensor() {
  const t = document.getElementById('sensor-tog-sensor');
  t.classList.toggle('on');
  const on = isOn(t);
  write(`${CORTEX}/sensor/enabled.txt`, on ? 'on' : 'off');
  txt('sensor-sensor-state', on ? 'Armed' : 'Idle');
  txt('sensor-sensor-status', on ? 'Will activate on next game launch' : 'Not running');
}
window.mod_sensor_toggleSensor = mod_sensor_toggleSensor;

async function loadSensor() {
  const en = await se(`cat "${CORTEX}/sensor/enabled.txt"`, 'off');
  setOn(document.getElementById('sensor-tog-sensor'), en === 'on');
  txt('sensor-sensor-state', en === 'on' ? 'Armed' : 'Idle');
  const homeRow = document.getElementById('home-row-sensor');
  if (homeRow) homeRow.style.display = en === 'on' ? '' : 'none';
}

async function mod_bypass_runScan() {
  const box = document.getElementById('bypass-status-box');
  if (box) box.innerHTML = '<div style="font-size:12px;color:var(--lavender-pale);">Scanning charge controller nodes… plug in and wait.</div>';
  toast('Bypass scan started — this can take a minute');
  const out = await se(`sh "${CORTEX}/battery/bypass_charge.sh" detect 2>&1 | tail -8`, '');
  const node = await se(`cat "${CORTEX}/battery/bypass_node.txt" 2>/dev/null`, '');
  if (node) {
    if (box) box.innerHTML = `<div style="font-size:12px;color:var(--ok);">Compatible node found.</div>`;
    document.getElementById('bypass-scan-row').style.display = 'none';
    document.getElementById('bypass-toggle-row').style.display = 'flex';
    txt('bypass-node-label', 'Using ' + node);
  } else {
    if (box) box.innerHTML = `<div style="font-size:12px;color:var(--warn);">No working node on this firmware.${out ? '<br>' + out.replace(/</g, '') : ''}</div>`;
  }
}
window.mod_bypass_runScan = mod_bypass_runScan;

async function loadBypass() {
  const node = await se(`cat "${CORTEX}/battery/bypass_node.txt" 2>/dev/null`, '');
  if (node) {
    document.getElementById('bypass-scan-row').style.display = 'none';
    document.getElementById('bypass-toggle-row').style.display = 'flex';
    txt('bypass-node-label', 'Using ' + node);
    const box = document.getElementById('bypass-status-box');
    if (box) box.innerHTML = '<div style="font-size:12px;color:var(--ok);">Previously detected node is saved.</div>';
  }
  const tog = document.getElementById('bypass-tog-bypass');
  const st = await se(`cat "${CORTEX}/battery/bypass_state.txt" 2>/dev/null`, 'off');
  setOn(tog, st === 'on');
  if (tog && !tog.dataset.wired) {
    tog.dataset.wired = '1';
    tog.addEventListener('click', () => {
      tog.classList.toggle('on');
      se(`sh "${CORTEX}/battery/bypass_charge.sh" ${isOn(tog) ? 'on' : 'off'}`);
      toast('Bypass: ' + (isOn(tog) ? 'on' : 'off'));
    });
  }
}

/* ── Settings extras (schedule / smart charge / spoof rotate) ── */
function toggleAutoSchedule(el) {
  el.classList.toggle('on');
  write(`${CORTEX}/ai/schedule_enabled.txt`, isOn(el) ? 'on' : 'off');
  toast('Auto schedule: ' + (isOn(el) ? 'on' : 'off'));
}
window.toggleAutoSchedule = toggleAutoSchedule;

function toggleSmartCharge(el) {
  el.classList.toggle('on');
  write(`${CORTEX}/battery/smart_charge_enabled.txt`, isOn(el) ? 'on' : 'off');
  toast('Smart charge: ' + (isOn(el) ? 'on' : 'off'));
}
window.toggleSmartCharge = toggleSmartCharge;

function toggleSpoofRotate(el) {
  el.classList.toggle('on');
  write(`${CORTEX}/games/spoof_rotate.txt`, isOn(el) ? 'on' : 'off');
  toast('Spoof rotation: ' + (isOn(el) ? 'on' : 'off'));
}
window.toggleSpoofRotate = toggleSpoofRotate;

async function promptScheduleVal(key) {
  const files = {
    night: `${CORTEX}/ai/schedule_night_hour.txt`,
    morning: `${CORTEX}/ai/schedule_morning_hour.txt`,
    bat: `${CORTEX}/ai/schedule_low_bat_pct.txt`,
  };
  const ids = { night: 'settings-sched-night', morning: 'settings-sched-morning', bat: 'settings-sched-bat' };
  const fmt = (k, n) => (k === 'bat' ? `${n}%` : `${n}:00`);
  const cur = await se(`cat "${files[key]}" 2>/dev/null`, key === 'bat' ? '15' : (key === 'night' ? '23' : '7'));
  const raw = window.prompt(key === 'bat' ? 'Low battery threshold (1–50)' : 'Hour (0–23)', cur);
  if (raw === null || raw === '') return;
  const n = parseInt(raw, 10);
  if (!Number.isFinite(n)) { toast('Enter a number'); return; }
  const max = key === 'bat' ? 50 : 23;
  const min = key === 'bat' ? 1 : 0;
  const clamped = Math.max(min, Math.min(max, n));
  await write(files[key], String(clamped));
  txt(ids[key], fmt(key, clamped));
}
window.promptScheduleVal = promptScheduleVal;

async function promptSmartCharge(key) {
  const files = {
    trickle: `${CORTEX}/battery/smart_charge_trickle.txt`,
    hour: `${CORTEX}/battery/smart_charge_full_hour.txt`,
  };
  const ids = { trickle: 'settings-smart-trickle', hour: 'settings-smart-hour' };
  const cur = await se(`cat "${files[key]}" 2>/dev/null`, key === 'trickle' ? '80' : '7');
  const raw = window.prompt(key === 'trickle' ? 'Trickle percent (50–95)' : 'Full-charge hour (0–23)', cur);
  if (raw === null || raw === '') return;
  const n = parseInt(raw, 10);
  if (!Number.isFinite(n)) { toast('Enter a number'); return; }
  const clamped = key === 'trickle' ? Math.max(50, Math.min(95, n)) : Math.max(0, Math.min(23, n));
  await write(files[key], String(clamped));
  txt(ids[key], key === 'trickle' ? `${clamped}%` : `${clamped}:00`);
}
window.promptSmartCharge = promptSmartCharge;

async function loadSettings() {
  const [sched, night, morning, bat, smart, trickle, hour, rotate, blur] = await batched([
    `cat "${CORTEX}/ai/schedule_enabled.txt" 2>/dev/null`,
    `cat "${CORTEX}/ai/schedule_night_hour.txt" 2>/dev/null`,
    `cat "${CORTEX}/ai/schedule_morning_hour.txt" 2>/dev/null`,
    `cat "${CORTEX}/ai/schedule_low_bat_pct.txt" 2>/dev/null`,
    `cat "${CORTEX}/battery/smart_charge_enabled.txt" 2>/dev/null`,
    `cat "${CORTEX}/battery/smart_charge_trickle.txt" 2>/dev/null`,
    `cat "${CORTEX}/battery/smart_charge_full_hour.txt" 2>/dev/null`,
    `cat "${CORTEX}/games/spoof_rotate.txt" 2>/dev/null`,
    `cat "${CORTEX}/settings/blur.txt" 2>/dev/null`,
  ]);
  setOn(document.getElementById('settings-tog-sched'), sched === 'on');
  setOn(document.getElementById('settings-tog-smartchg'), smart === 'on');
  setOn(document.getElementById('settings-tog-rotate'), rotate === 'on');
  setOn(document.getElementById('settings-tog-blur'), blur !== 'off');
  txt('settings-sched-night', `${night || '23'}:00`);
  txt('settings-sched-morning', `${morning || '7'}:00`);
  txt('settings-sched-bat', `${bat || '15'}%`);
  txt('settings-smart-trickle', `${trickle || '80'}%`);
  txt('settings-smart-hour', `${hour || '7'}:00`);
}

window.addEventListener('popstate', (e) => {
  const key = (e.state && e.state.panel) || (location.hash ? location.hash.slice(1) : 'home');
  showPanel(key || 'home');
});

document.addEventListener('DOMContentLoaded', async () => {
  try {
    if (typeof ksu !== 'undefined' && typeof ksu.fullScreen === 'function') ksu.fullScreen(true);
  } catch (e) {}
  try { history.replaceState({ panel: 'home' }, '', '#home'); } catch (e) {}
  const [saved, blurSaved] = await batched([
    `cat "${CORTEX}/settings/theme.txt" 2>/dev/null`,
    `cat "${CORTEX}/settings/blur.txt" 2>/dev/null`,
  ]);
  const theme = saved || document.documentElement.getAttribute('data-theme') || 'lavender';
  setTheme(theme);
  const blurOn = blurSaved !== 'off';
  setBlurEnabled(blurOn);
  const key = location.hash ? location.hash.slice(1) : 'home';
  if (key && key !== 'home') shellNav(key, { replace: PRIMARY_TABS.has(key) });
  else showPanel('home');
  setInterval(() => {
    const home = document.getElementById('panel-home');
    if (home && home.style.display !== 'none') refreshHome();
  }, 8000);
});

// Cooldown — лимиты Codex и Claude для виджетов iPhone.
// Данные берутся с вашего Home Assistant, куда их отправляет Cooldown на Mac.
// Виджеты: на экран блокировки (прямоугольный, круглый) и на «Домой» (маленький, средний).

const HA = "__HA_URL__";
const TOKEN = "__HA_TOKEN__";
const AGENTS = [
  { id: "codex", name: "Codex", color: "#5C80FF" },
  { id: "claude", name: "Claude", color: "#D97757" },
];

// ---------- data ----------
const fm = FileManager.local();
const cachePath = fm.joinPath(fm.documentsDirectory(), "cooldown-cache.json");

async function load() {
  try {
    const out = {};
    for (const a of AGENTS) {
      const r = new Request(`${HA}/api/states/sensor.cooldown_${a.id}`);
      r.headers = { Authorization: `Bearer ${TOKEN}` };
      r.timeoutInterval = 8;
      const s = await r.loadJSON();
      out[a.id] = {
        left: parseFloat(s.state),
        weekly: s.attributes.weekly,
        reset: s.attributes.resets_at,
        exhausted: s.attributes.exhausted === true,
      };
    }
    out.at = Date.now();
    fm.writeString(cachePath, JSON.stringify(out));
    return out;
  } catch (e) {
    if (fm.fileExists(cachePath)) {
      const cached = JSON.parse(fm.readString(cachePath));
      cached.stale = true;
      return cached;
    }
    return null;
  }
}

// ---------- colours: green → yellow → orange → red, smooth ----------
const STOPS = [[0, [240, 69, 69]], [12, [245, 84, 61]], [30, [250, 148, 41]], [50, [245, 204, 46]], [72, [115, 209, 92]], [100, [77, 204, 107]]];
function level(v) {
  v = Math.max(0, Math.min(100, v));
  for (let i = 0; i < STOPS.length - 1; i++) {
    const [a, ca] = STOPS[i], [b, cb] = STOPS[i + 1];
    if (v >= a && v <= b) {
      let t = (v - a) / (b - a); t = t * t * (3 - 2 * t);
      const c = ca.map((x, k) => Math.round(x + (cb[k] - x) * t));
      return new Color(`#${c.map(x => x.toString(16).padStart(2, "0")).join("")}`);
    }
  }
  return new Color("#4DCC6B");
}

function time(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  const f = new DateFormatter();
  const sameDay = new Date().toDateString() === d.toDateString();
  f.dateFormat = sameDay ? "HH:mm" : "EEE HH:mm";
  f.locale = "ru_RU";
  return f.string(d);
}

// A rounded bar drawn as an image, so it looks the same everywhere.
function bar(width, height, value, color, track) {
  const ctx = new DrawContext();
  ctx.size = new Size(width, height);
  ctx.opaque = false;
  ctx.respectScreenScale = true;
  const r = height / 2;
  const back = new Path(); back.addRoundedRect(new Rect(0, 0, width, height), r, r);
  ctx.addPath(back); ctx.setFillColor(track); ctx.fillPath();
  if (value > 0.5) {
    const w = Math.max(height, width * Math.min(100, value) / 100);
    const fill = new Path(); fill.addRoundedRect(new Rect(0, 0, w, height), r, r);
    ctx.addPath(fill); ctx.setFillColor(color); ctx.fillPath();
  }
  return ctx.getImage();
}

// ---------- widgets ----------
const family = config.widgetFamily || "medium";
const data = await load();
const w = new ListWidget();
w.refreshAfterDate = new Date(Date.now() + 5 * 60 * 1000);

if (!data) {
  w.addText(family.startsWith("accessory") ? "Cooldown: нет данных" : "Cooldown: нет связи с Home Assistant").font = Font.systemFont(12);
} else if (family === "accessoryCircular") {
  // The lower of the two, as a ring with the number.
  const low = AGENTS.map(a => data[a.id]).filter(Boolean).sort((x, y) => x.left - y.left)[0];
  const s = w.addStack(); s.layoutVertically(); s.centerAlignContent();
  const t = s.addText(`${Math.round(low.left)}%`); t.font = Font.boldRoundedSystemFont(16); t.centerAlignText();
  const c = s.addText(low.exhausted ? time(low.reset) : "лимит"); c.font = Font.systemFont(9); c.centerAlignText();
} else if (family === "accessoryRectangular") {
  for (const a of AGENTS) {
    const d = data[a.id]; if (!d) continue;
    const row = w.addStack(); row.centerAlignContent(); row.spacing = 4;
    const n = row.addText(a.name); n.font = Font.semiboldSystemFont(12); n.lineLimit = 1;
    n.minimumScaleFactor = 0.8;
    row.addSpacer(4);
    row.addImage(bar(60, 6, d.left, Color.white(), new Color("#FFFFFF", 0.25))).imageSize = new Size(60, 6);
    row.addSpacer(4);
    const v = row.addText(d.exhausted ? time(d.reset) : `${Math.round(d.left)}%`);
    v.font = Font.semiboldMonospacedSystemFont(12);
    w.addSpacer(3);
  }
} else {
  // Home Screen: colour, reset times and the week.
  w.backgroundGradient = (() => { const g = new LinearGradient(); g.colors = [new Color("#151A33"), new Color("#07080F")]; g.locations = [0, 1]; return g; })();
  w.setPadding(14, 14, 12, 14);
  const head = w.addStack(); head.centerAlignContent();
  const title = head.addText("Cooldown"); title.font = Font.boldRoundedSystemFont(14); title.textColor = Color.white();
  head.addSpacer();
  if (data.stale) { const st = head.addText("нет связи"); st.font = Font.systemFont(9); st.textColor = new Color("#FFFFFF", 0.5); }
  w.addSpacer(8);
  const width = family === "small" ? 120 : 280;
  for (const a of AGENTS) {
    const d = data[a.id]; if (!d) continue;
    const top = w.addStack(); top.centerAlignContent();
    const dot = top.addText("●"); dot.font = Font.systemFont(9); dot.textColor = new Color(a.color);
    top.addSpacer(4);
    const n = top.addText(a.name); n.font = Font.semiboldSystemFont(12); n.textColor = Color.white();
    top.addSpacer();
    const v = top.addText(d.exhausted ? `сброс ${time(d.reset)}` : `${Math.round(d.left)}%`);
    v.font = Font.semiboldMonospacedSystemFont(12); v.textColor = d.exhausted ? new Color("#FF6B6B") : Color.white();
    w.addSpacer(4);
    w.addImage(bar(width, 7, d.left, level(d.left), new Color("#FFFFFF", 0.12))).imageSize = new Size(width, 7);
    if (family !== "small") {
      w.addSpacer(3);
      const sub = w.addText(`сброс ${time(d.reset)} · неделя ${Math.round(d.weekly ?? 0)}%`);
      sub.font = Font.systemFont(10); sub.textColor = new Color("#FFFFFF", 0.55);
    }
    w.addSpacer(8);
  }
}

if (config.runsInWidget) Script.setWidget(w);
else await w.presentMedium();
Script.complete();

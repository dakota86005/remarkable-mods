// Up Next - iCalendar (.ics) reader, v1
// Turns the text of an .ics feed into a short list of upcoming occurrences:
//   [{ s: startMs, e: endMs, a: 1 if all-day, t: title, l: location }]
// Handles line folding, escaped text, VTIMEZONE (and common zone names without
// one), floating times, all-day dates, DTEND or DURATION, RRULE (daily, weekly,
// monthly, yearly with INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH,
// BYSETPOS, WKST), RDATE, EXDATE, RECURRENCE-ID overrides and cancelled events.
//
// Runs inside a QML WorkerScript (so a large feed never stalls the pen), or on
// the main thread through new Function() as a fallback. Plain ES5, no imports.
// Times are converted to real instants; all-day events become local midnights,
// so the tablet's own time zone decides what "today" is.

var DAY = 86400000;
var WD = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };

// ---------- lines and properties

function unfold(text) {
    var raw = String(text).split(/\r\n|\n|\r/);
    var out = [];
    for (var i = 0; i < raw.length; i++) {
        var ln = raw[i];
        var c = ln.charAt(0);
        if ((c === " " || c === "\t") && out.length) {
            out[out.length - 1] += ln.substring(1);
        } else if (ln.length) {
            out.push(ln);
        }
    }
    return out;
}

// "DTSTART;TZID=America/Phoenix:20261125T090000" -> {name, params, value}
function prop(line) {
    var q = false, colon = -1;
    for (var i = 0; i < line.length; i++) {
        var ch = line.charAt(i);
        if (ch === '"') q = !q;
        else if (ch === ":" && !q) { colon = i; break; }
    }
    if (colon < 0) return null;
    var head = line.substring(0, colon);
    var value = line.substring(colon + 1);
    var parts = head.split(";");
    var params = {};
    for (var k = 1; k < parts.length; k++) {
        var eq = parts[k].indexOf("=");
        if (eq > 0) {
            var pv = parts[k].substring(eq + 1);
            if (pv.charAt(0) === '"') pv = pv.substring(1, pv.length - 1);
            params[parts[k].substring(0, eq).toUpperCase()] = pv;
        }
    }
    return { name: parts[0].toUpperCase(), params: params, value: value };
}

function unescapeText(s) {
    return String(s).replace(/\\([\\;,nN])/g, function (m, c) {
        return (c === "n" || c === "N") ? " " : c;
    }).replace(/\s+/g, " ").trim();
}

// ---------- dates
// A date value keeps its wall-clock time as "fake UTC" ms (Date.UTC of the
// written fields) plus how to read it: z (UTC), tz (zone id) or floating.

function parseDate(value, params) {
    var v = String(value).trim();
    var m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?/.exec(v);
    if (m === null) return null;
    var y = +m[1], mo = +m[2] - 1, d = +m[3];
    var allDay = (params && params.VALUE === "DATE") || m[4] === undefined;
    if (allDay) return { allDay: true, wall: Date.UTC(y, mo, d), z: false, tz: null };
    var wall = Date.UTC(y, mo, d, +m[4], +m[5], m[6] ? +m[6] : 0);
    return { allDay: false, wall: wall, z: m[7] === "Z", tz: (m[7] === "Z") ? null : ((params && params.TZID) || null) };
}

function parseDateList(value, params) {
    var out = [];
    var parts = String(value).split(",");
    for (var i = 0; i < parts.length; i++) {
        var dv = parseDate(parts[i], params);
        if (dv) out.push(dv);
    }
    return out;
}

function parseOffset(s) {
    var m = /^([+-])(\d{2})(\d{2})/.exec(String(s).trim());
    if (m === null) return 0;
    var mins = (+m[2]) * 60 + (+m[3]);
    return m[1] === "-" ? -mins : mins;
}

function parseDuration(s) {
    var m = /^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/.exec(String(s).trim());
    if (m === null) return 0;
    var ms = ((+m[2] || 0) * 7 + (+m[3] || 0)) * DAY + (+m[4] || 0) * 3600000 + (+m[5] || 0) * 60000 + (+m[6] || 0) * 1000;
    return m[1] === "-" ? -ms : ms;
}

function fields(wall) {
    var d = new Date(wall);
    return { y: d.getUTCFullYear(), m: d.getUTCMonth(), d: d.getUTCDate(), h: d.getUTCHours(), mi: d.getUTCMinutes(), s: d.getUTCSeconds(), wd: d.getUTCDay() };
}

// ---------- time zones

// Zones without a VTIMEZONE block: standard offset (min) and DST rule.
var BUILTIN = {
    "UTC": [0, null], "Etc/UTC": [0, null], "GMT": [0, null], "Etc/GMT": [0, null], "Z": [0, null],
    "America/Phoenix": [-420, null], "US/Arizona": [-420, null], "MST": [-420, null],
    "Pacific/Honolulu": [-600, null], "US/Hawaii": [-600, null],
    "America/New_York": [-300, "US"], "US/Eastern": [-300, "US"], "America/Detroit": [-300, "US"], "America/Toronto": [-300, "US"],
    "America/Chicago": [-360, "US"], "US/Central": [-360, "US"],
    "America/Denver": [-420, "US"], "US/Mountain": [-420, "US"], "America/Boise": [-420, "US"], "America/Edmonton": [-420, "US"],
    "America/Los_Angeles": [-480, "US"], "US/Pacific": [-480, "US"], "America/Vancouver": [-480, "US"], "America/Tijuana": [-480, "US"],
    "America/Anchorage": [-540, "US"], "US/Alaska": [-540, "US"],
    "America/Mexico_City": [-360, null], "America/Hermosillo": [-420, null],
    "Europe/London": [0, "EU"], "Europe/Dublin": [0, "EU"], "Europe/Lisbon": [0, "EU"],
    "Europe/Paris": [60, "EU"], "Europe/Berlin": [60, "EU"], "Europe/Madrid": [60, "EU"], "Europe/Rome": [60, "EU"],
    "Europe/Amsterdam": [60, "EU"], "Europe/Brussels": [60, "EU"], "Europe/Vienna": [60, "EU"], "Europe/Zurich": [60, "EU"],
    "Europe/Stockholm": [60, "EU"], "Europe/Oslo": [60, "EU"], "Europe/Copenhagen": [60, "EU"], "Europe/Prague": [60, "EU"],
    "Europe/Warsaw": [60, "EU"], "Europe/Athens": [120, "EU"], "Europe/Helsinki": [120, "EU"],
    "Asia/Tokyo": [540, null], "Asia/Seoul": [540, null], "Asia/Shanghai": [480, null], "Asia/Hong_Kong": [480, null],
    "Asia/Singapore": [480, null], "Asia/Kolkata": [330, null], "Asia/Calcutta": [330, null], "Asia/Dubai": [240, null]
};

// nth weekday of a month (n > 0 from the start, n < 0 from the end); day of month or 0
function nthWeekday(y, m, wd, n) {
    var last = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
    if (n > 0) {
        var first = new Date(Date.UTC(y, m, 1)).getUTCDay();
        var d = 1 + ((wd - first + 7) % 7) + (n - 1) * 7;
        return d <= last ? d : 0;
    }
    var lastWd = new Date(Date.UTC(y, m, last)).getUTCDay();
    var dd = last - ((lastWd - wd + 7) % 7) + (n + 1) * 7;
    return dd >= 1 ? dd : 0;
}

function builtinTransitions(rule, std, year) {
    // returns [{at: wall ms in the offset before the change, to: minutes}]
    if (rule === "US") {
        return [
            { at: Date.UTC(year, 2, nthWeekday(year, 2, 0, 2), 2), to: std + 60 },
            { at: Date.UTC(year, 10, nthWeekday(year, 10, 0, 1), 2), to: std }
        ];
    }
    if (rule === "EU") {
        // 01:00 UTC, written in local wall time of the offset in force before the change
        return [
            { at: Date.UTC(year, 2, nthWeekday(year, 2, 0, -1), 1) + std * 60000, to: std + 60 },
            { at: Date.UTC(year, 9, nthWeekday(year, 9, 0, -1), 1) + (std + 60) * 60000, to: std }
        ];
    }
    return [];
}

function Zones() {
    this.defs = {};      // tzid -> [{from, to, start(wall), rrule, rdates}]
    this.cache = {};     // tzid|year -> transitions
}

Zones.prototype.add = function (tzid, comps) {
    if (tzid && comps.length) this.defs[tzid] = comps;
};

Zones.prototype.known = function (tzid) {
    return this.defs.hasOwnProperty(tzid) || BUILTIN.hasOwnProperty(tzid);
};

Zones.prototype.transitions = function (tzid, year) {
    var key = tzid + "|" + year;
    if (this.cache.hasOwnProperty(key)) return this.cache[key];
    var list = [];
    var comps = this.defs[tzid];
    if (comps) {
        for (var i = 0; i < comps.length; i++) {
            var c = comps[i];
            var f = fields(c.start);
            if (c.rrule && c.rrule.freq === "YEARLY") {
                if (year >= f.y) {
                    var months = c.rrule.bymonth.length ? c.rrule.bymonth : [f.m + 1];
                    for (var k = 0; k < months.length; k++) {
                        var mo = months[k] - 1;
                        var day = f.d;
                        if (c.rrule.byday.length) {
                            var bd = c.rrule.byday[0];
                            day = nthWeekday(year, mo, bd.wd, bd.n || 1);
                        } else if (c.rrule.bymonthday.length) {
                            day = c.rrule.bymonthday[0];
                        }
                        if (day > 0) {
                            var at = Date.UTC(year, mo, day, f.h, f.mi, f.s);
                            var untilOk = c.rrule.until === null || at <= c.rrule.until.wall + (c.rrule.until.z ? c.from * 60000 : 0);
                            if (untilOk) list.push({ at: at, to: c.to });
                        }
                    }
                }
            } else {
                if (f.y === year) list.push({ at: c.start, to: c.to });
            }
            for (var r = 0; r < c.rdates.length; r++) {
                if (fields(c.rdates[r]).y === year) list.push({ at: c.rdates[r], to: c.to });
            }
        }
    } else if (BUILTIN.hasOwnProperty(tzid)) {
        list = builtinTransitions(BUILTIN[tzid][1], BUILTIN[tzid][0], year);
    }
    list.sort(function (a, b) { return a.at - b.at; });
    this.cache[key] = list;
    return list;
};

// UTC offset in minutes for a wall-clock time in a zone, or null if unknown
Zones.prototype.offset = function (tzid, wall) {
    if (this.known(tzid) === false) return null;
    var y = new Date(wall).getUTCFullYear();
    for (var yy = y; yy >= y - 1; yy--) {
        var t = this.transitions(tzid, yy);
        for (var i = t.length - 1; i >= 0; i--) {
            if (t[i].at <= wall) return t[i].to;
        }
    }
    if (this.defs[tzid]) {
        // before every listed change: earliest component's offset
        var comps = this.defs[tzid], best = comps[0];
        for (var k = 1; k < comps.length; k++) if (comps[k].start < best.start) best = comps[k];
        return best.from;
    }
    return BUILTIN[tzid][0];
};

// Real instant (ms) for a date value written in wall-clock fields
Zones.prototype.instant = function (dv, wall) {
    var w = (wall === undefined) ? dv.wall : wall;
    var f;
    if (dv.allDay) {
        f = fields(w);
        return new Date(f.y, f.m, f.d).getTime();
    }
    if (dv.z) return w;
    if (dv.tz) {
        var off = this.offset(dv.tz, w);
        if (off !== null) return w - off * 60000;
    }
    f = fields(w);
    return new Date(f.y, f.m, f.d, f.h, f.mi, f.s).getTime();
};

// ---------- recurrence rules

function parseRule(value) {
    var r = { freq: "", interval: 1, count: 0, until: null, byday: [], bymonthday: [], bymonth: [], bysetpos: [], wkst: 1 };
    var parts = String(value).split(";");
    for (var i = 0; i < parts.length; i++) {
        var kv = parts[i].split("=");
        var k = (kv[0] || "").toUpperCase(), v = kv[1] || "";
        var list = v.split(",");
        var j;
        if (k === "FREQ") r.freq = v.toUpperCase();
        else if (k === "INTERVAL") r.interval = Math.max(1, parseInt(v, 10) || 1);
        else if (k === "COUNT") r.count = parseInt(v, 10) || 0;
        else if (k === "UNTIL") r.until = parseDate(v, null);
        else if (k === "WKST" && WD.hasOwnProperty(v)) r.wkst = WD[v];
        else if (k === "BYDAY") {
            for (j = 0; j < list.length; j++) {
                var m = /^([+-]?\d+)?([A-Z]{2})$/.exec(list[j].trim().toUpperCase());
                if (m && WD.hasOwnProperty(m[2])) r.byday.push({ n: m[1] ? parseInt(m[1], 10) : 0, wd: WD[m[2]] });
            }
        } else if (k === "BYMONTHDAY") {
            for (j = 0; j < list.length; j++) if (parseInt(list[j], 10)) r.bymonthday.push(parseInt(list[j], 10));
        } else if (k === "BYMONTH") {
            for (j = 0; j < list.length; j++) if (parseInt(list[j], 10)) r.bymonth.push(parseInt(list[j], 10));
        } else if (k === "BYSETPOS") {
            for (j = 0; j < list.length; j++) if (parseInt(list[j], 10)) r.bysetpos.push(parseInt(list[j], 10));
        }
    }
    return r;
}

function inList(list, v) {
    for (var i = 0; i < list.length; i++) if (list[i] === v) return true;
    return false;
}

function applySetPos(days, setpos) {
    if (setpos.length === 0) return days;
    var out = [];
    for (var i = 0; i < setpos.length; i++) {
        var p = setpos[i];
        var idx = p > 0 ? p - 1 : days.length + p;
        if (idx >= 0 && idx < days.length && inList(out, days[idx]) === false) out.push(days[idx]);
    }
    out.sort(function (a, b) { return a - b; });
    return out;
}

// Days (1..31) of month m in year y picked by the rule; base = day of DTSTART
function monthDays(r, y, m, baseDay, defaultToBase) {
    var last = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
    var days = [], d, i;
    var fromMonthDay = [];
    for (i = 0; i < r.bymonthday.length; i++) {
        d = r.bymonthday[i] > 0 ? r.bymonthday[i] : last + 1 + r.bymonthday[i];
        if (d >= 1 && d <= last) fromMonthDay.push(d);
    }
    var fromDay = [];
    for (i = 0; i < r.byday.length; i++) {
        var bd = r.byday[i];
        if (bd.n) {
            d = nthWeekday(y, m, bd.wd, bd.n);
            if (d) fromDay.push(d);
        } else {
            for (d = 1; d <= last; d++) if (new Date(Date.UTC(y, m, d)).getUTCDay() === bd.wd) fromDay.push(d);
        }
    }
    if (r.bymonthday.length && r.byday.length) {
        for (i = 0; i < fromMonthDay.length; i++) if (inList(fromDay, fromMonthDay[i])) days.push(fromMonthDay[i]);
    } else if (r.bymonthday.length) {
        days = fromMonthDay;
    } else if (r.byday.length) {
        days = fromDay;
    } else if (defaultToBase && baseDay <= last) {
        days = [baseDay];
    }
    days.sort(function (a, b) { return a - b; });
    var uniq = [];
    for (i = 0; i < days.length; i++) if (i === 0 || days[i] !== days[i - 1]) uniq.push(days[i]);
    return applySetPos(uniq, r.bysetpos);
}

// Wall-clock starts for period i of the rule (sorted)
function periodStarts(r, base, bf, i) {
    var out = [], k, d, w;
    var tod = bf.h * 3600000 + bf.mi * 60000 + bf.s * 1000;
    if (r.freq === "DAILY") {
        w = base + i * r.interval * DAY;
        var f = fields(w);
        var ok = true;
        if (r.bymonth.length && inList(r.bymonth, f.m + 1) === false) ok = false;
        if (ok && r.byday.length) {
            ok = false;
            for (k = 0; k < r.byday.length; k++) if (r.byday[k].wd === f.wd) ok = true;
        }
        if (ok && r.bymonthday.length) {
            var lastD = new Date(Date.UTC(f.y, f.m + 1, 0)).getUTCDate();
            ok = false;
            for (k = 0; k < r.bymonthday.length; k++) {
                var md = r.bymonthday[k] > 0 ? r.bymonthday[k] : lastD + 1 + r.bymonthday[k];
                if (md === f.d) ok = true;
            }
        }
        if (ok) out.push(w);
    } else if (r.freq === "WEEKLY") {
        var baseMidnight = base - tod;
        var weekStart = baseMidnight - ((bf.wd - r.wkst + 7) % 7) * DAY + i * r.interval * 7 * DAY;
        var wds = [];
        if (r.byday.length) for (k = 0; k < r.byday.length; k++) wds.push(r.byday[k].wd);
        else wds.push(bf.wd);
        for (k = 0; k < wds.length; k++) {
            w = weekStart + ((wds[k] - r.wkst + 7) % 7) * DAY + tod;
            if (r.bymonth.length === 0 || inList(r.bymonth, fields(w).m + 1)) out.push(w);
        }
        out = applySetPos(out.sort(function (a, b) { return a - b; }), r.bysetpos);
    } else if (r.freq === "MONTHLY") {
        var mi = bf.m + i * r.interval;
        var y = bf.y + Math.floor(mi / 12), m = ((mi % 12) + 12) % 12;
        if (r.bymonth.length === 0 || inList(r.bymonth, m + 1)) {
            var days = monthDays(r, y, m, bf.d, true);
            for (k = 0; k < days.length; k++) out.push(Date.UTC(y, m, days[k]) + tod);
        }
    } else if (r.freq === "YEARLY") {
        var yy = bf.y + i * r.interval;
        var months = r.bymonth.length ? r.bymonth.slice(0) : [bf.m + 1];
        months.sort(function (a, b) { return a - b; });
        var all = [];
        if (r.bymonth.length === 0 && r.byday.length && r.bymonthday.length === 0 && r.byday[0].n) {
            // e.g. BYDAY=20MO without BYMONTH: nth weekday of the year
            for (k = 0; k < r.byday.length; k++) {
                var bd = r.byday[k];
                var jan1 = new Date(Date.UTC(yy, 0, 1)).getUTCDay();
                var dec31 = Date.UTC(yy, 11, 31);
                var dayMs;
                if (bd.n > 0) dayMs = Date.UTC(yy, 0, 1) + (((bd.wd - jan1 + 7) % 7) + (bd.n - 1) * 7) * DAY;
                else dayMs = dec31 - ((new Date(dec31).getUTCDay() - bd.wd + 7) % 7) * DAY + (bd.n + 1) * 7 * DAY;
                if (new Date(dayMs).getUTCFullYear() === yy) all.push(dayMs + tod);
            }
        } else {
            var noDayRule = r.byday.length === 0 && r.bymonthday.length === 0;
            for (k = 0; k < months.length; k++) {
                var mm = months[k] - 1;
                var sub = { byday: r.byday, bymonthday: r.bymonthday, bysetpos: [] };
                var ds = monthDays(sub, yy, mm, bf.d, noDayRule);
                for (d = 0; d < ds.length; d++) all.push(Date.UTC(yy, mm, ds[d]) + tod);
            }
        }
        all.sort(function (a, b) { return a - b; });
        out = applySetPos(all, r.bysetpos);
    }
    return out;
}

// ---------- calendar

function readCalendar(text) {
    var lines = unfold(text);
    var zones = new Zones();
    var events = [];
    var name = "";
    var stack = [];
    var ev = null, tz = null, tzComp = null, tzComps = [];
    for (var i = 0; i < lines.length; i++) {
        var p = prop(lines[i]);
        if (p === null) continue;
        if (p.name === "BEGIN") {
            var what = p.value.toUpperCase();
            stack.push(what);
            if (what === "VEVENT") ev = { exdates: [], rdates: [] };
            else if (what === "VTIMEZONE") { tz = null; tzComps = []; }
            else if ((what === "STANDARD" || what === "DAYLIGHT") && stack[stack.length - 2] === "VTIMEZONE") {
                tzComp = { from: 0, to: 0, start: 0, rrule: null, rdates: [] };
            }
            continue;
        }
        if (p.name === "END") {
            var ended = p.value.toUpperCase();
            stack.pop();
            if (ended === "VEVENT" && ev) { events.push(ev); ev = null; }
            else if ((ended === "STANDARD" || ended === "DAYLIGHT") && tzComp) { tzComps.push(tzComp); tzComp = null; }
            else if (ended === "VTIMEZONE") { zones.add(tz, tzComps); tz = null; tzComps = []; }
            continue;
        }
        var top = stack[stack.length - 1];
        if (top === "VEVENT" && ev) {
            var n = p.name;
            if (n === "DTSTART") ev.start = parseDate(p.value, p.params);
            else if (n === "DTEND") ev.end = parseDate(p.value, p.params);
            else if (n === "DURATION") ev.duration = parseDuration(p.value);
            else if (n === "SUMMARY") ev.title = unescapeText(p.value);
            else if (n === "LOCATION") ev.location = unescapeText(p.value);
            else if (n === "UID") ev.uid = p.value;
            else if (n === "STATUS") ev.status = p.value.toUpperCase();
            else if (n === "TRANSP") ev.transp = p.value.toUpperCase();
            else if (n === "RRULE") ev.rrule = parseRule(p.value);
            else if (n === "RECURRENCE-ID") ev.recurrenceId = parseDate(p.value, p.params);
            else if (n === "EXDATE") ev.exdates = ev.exdates.concat(parseDateList(p.value, p.params));
            else if (n === "RDATE" && (p.params.VALUE || "") !== "PERIOD") ev.rdates = ev.rdates.concat(parseDateList(p.value, p.params));
        } else if (tzComp && (top === "STANDARD" || top === "DAYLIGHT")) {
            if (p.name === "TZOFFSETFROM") tzComp.from = parseOffset(p.value);
            else if (p.name === "TZOFFSETTO") tzComp.to = parseOffset(p.value);
            else if (p.name === "DTSTART") { var sd = parseDate(p.value, null); if (sd) tzComp.start = sd.wall; }
            else if (p.name === "RRULE") tzComp.rrule = parseRule(p.value);
            else if (p.name === "RDATE") {
                var rl = parseDateList(p.value, null);
                for (var q = 0; q < rl.length; q++) tzComp.rdates.push(rl[q].wall);
            }
        } else if (top === "VTIMEZONE") {
            if (p.name === "TZID") tz = p.value;
        } else if (top === "VCALENDAR") {
            if (p.name === "X-WR-CALNAME") name = unescapeText(p.value);
        }
    }
    return { name: name, zones: zones, events: events };
}

// Occurrences that overlap [from, to) (ms), sorted by start
function upcoming(text, from, to, maxCount) {
    var cal = readCalendar(text);
    var zones = cal.zones;
    var out = [];
    var overrides = {};
    var unknownZones = {};
    var i, ev;

    function emit(ev, s, e, allDay) {
        if (e <= s) e = s + (allDay ? DAY : 1);
        if (e > from && s < to) {
            out.push({ s: s, e: e, a: allDay ? 1 : 0, t: ev.title || "Busy", l: ev.location || "" });
        }
    }

    function note(dv) {
        if (dv && dv.tz && zones.known(dv.tz) === false) unknownZones[dv.tz] = true;
    }

    // Moved or cancelled single occurrences of a series
    for (i = 0; i < cal.events.length; i++) {
        ev = cal.events[i];
        if (ev.recurrenceId && ev.uid) overrides[ev.uid + "|" + zones.instant(ev.recurrenceId)] = true;
    }

    for (i = 0; i < cal.events.length; i++) {
        ev = cal.events[i];
        if (ev.start === undefined || ev.start === null) continue;
        note(ev.start);
        var allDay = ev.start.allDay;
        // length in wall-clock ms (keeps 9:00-10:00 across a DST change)
        var dur;
        if (ev.end) {
            if (ev.end.allDay === allDay && ev.end.z === ev.start.z && ev.end.tz === ev.start.tz) dur = ev.end.wall - ev.start.wall;
            else dur = zones.instant(ev.end) - zones.instant(ev.start);
        } else if (ev.duration) {
            dur = ev.duration;
        } else {
            dur = allDay ? DAY : 0;
        }
        if (dur < 0) dur = 0;
        var cancelled = ev.status === "CANCELLED";

        if (ev.recurrenceId || ev.rrule === undefined) {
            if (cancelled === false) {
                emit(ev, zones.instant(ev.start), zones.instant(ev.start, ev.start.wall + dur), allDay);
            }
            if (ev.recurrenceId || ev.rdates.length === 0) continue;
        }
        if (cancelled) continue;

        var ex = {};
        for (var x = 0; x < ev.exdates.length; x++) {
            var exd = ev.exdates[x];
            if (exd.allDay) {
                var ef = fields(exd.wall);
                ex["d" + ef.y + "-" + ef.m + "-" + ef.d] = true;
            } else {
                ex["t" + zones.instant(exd.z || exd.tz ? exd : { allDay: false, wall: exd.wall, z: false, tz: ev.start.tz })] = true;
            }
        }
        var seen = {};
        var take = function (wall) {
            var s = zones.instant(ev.start, wall);
            if (seen[s]) return;
            seen[s] = true;
            var wf = fields(wall);
            if (ex["t" + s] || ex["d" + wf.y + "-" + wf.m + "-" + wf.d]) return;
            if (ev.uid && overrides[ev.uid + "|" + s]) return;
            emit(ev, s, zones.instant(ev.start, wall + dur), allDay);
        };

        for (var rd = 0; rd < ev.rdates.length; rd++) take(ev.rdates[rd].wall);
        if (ev.rrule === undefined) continue;

        var r = ev.rrule;
        if (r.freq !== "DAILY" && r.freq !== "WEEKLY" && r.freq !== "MONTHLY" && r.freq !== "YEARLY") continue;
        var base = ev.start.wall;
        var bf = fields(base);
        var untilMs = null;
        if (r.until) {
            untilMs = r.until.allDay ? zones.instant(r.until) + DAY - 1 : (r.until.z ? r.until.wall : zones.instant({ allDay: false, wall: r.until.wall, z: false, tz: ev.start.tz }));
            if (allDay && r.until.allDay === false) untilMs = r.until.wall + DAY - 1 + 14 * 3600000;
        }

        // Jump close to the window when nothing needs counting from the start
        var first = 0;
        if (r.count === 0) {
            var gap = (from - dur - 2 * DAY) - base;
            if (gap > 0) {
                var per = r.freq === "DAILY" ? DAY : r.freq === "WEEKLY" ? 7 * DAY : r.freq === "MONTHLY" ? 31 * DAY : 366 * DAY;
                first = Math.max(0, Math.floor(gap / (per * r.interval)) - 1);
            }
        }
        // DTSTART is always the first occurrence, even when the rule would skip it
        var counted = 0, done = false;
        if (untilMs === null || zones.instant(ev.start) <= untilMs) take(base);
        for (var pi = first; pi < first + 20000 && done === false; pi++) {
            var starts = periodStarts(r, base, bf, pi);
            for (var si = 0; si < starts.length; si++) {
                var w = starts[si];
                if (w < base) continue;
                var inst = zones.instant(ev.start, w);
                if (untilMs !== null && inst > untilMs) { done = true; break; }
                counted++;
                if (r.count && counted > r.count) { done = true; break; }
                if (inst >= to) { done = true; break; }
                if (w > base) take(w);
            }
            // a period far past the window ends the search even with no matches
            if (starts.length === 0 && pi > first + 5000) done = true;
        }
    }

    out.sort(function (a, b) { return a.s - b.s || a.a - b.a; });
    if (maxCount && out.length > maxCount) out = out.slice(0, maxCount);
    var uz = [];
    for (var z in unknownZones) if (unknownZones.hasOwnProperty(z)) uz.push(z);
    return { name: cal.name, events: out, total: cal.events.length, unknownZones: uz };
}

// ---------- WorkerScript entry (ignored on the main thread)

if (typeof WorkerScript !== "undefined" && typeof UPNEXT_MAIN_THREAD === "undefined") {
    WorkerScript.onMessage = function (msg) {
        var reply = { id: msg.id, url: msg.url, ok: false };
        try {
            var r = upcoming(msg.text, msg.from, msg.to, msg.max || 400);
            reply.ok = true;
            reply.name = r.name;
            reply.events = r.events;
            reply.total = r.total;
            reply.unknownZones = r.unknownZones;
        } catch (e) {
            reply.error = "" + e;
        }
        WorkerScript.sendMessage(reply);
    };
}

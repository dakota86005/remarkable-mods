.pragma library
// Pure helpers for the Mods app: snapshot parsing, apk version rules and the package model.

var DEVICES = ["rm1", "rm2", "rmpp", "rmppmove", "rmppure"];
var VIRTUAL = ["remarkable-os", "rm1", "rm2", "rmpp", "rmppmove", "rmppure"];
var DAKOTA_DESC = "Dakota's reMarkable mods";

// ---------------------------------------------------------------- versions (apk rules, simplified)
var SUFFIX = { alpha: -4, beta: -3, pre: -2, rc: -1, "": 0, cvs: 1, svn: 2, git: 3, hg: 4, p: 5 };

function vparse(v) {
    v = String(v || "");
    var rel = 0;
    var m = /-r(\d+)$/.exec(v);
    if (m) { rel = parseInt(m[1], 10); v = v.slice(0, m.index); }
    var parts = v.split("_");
    var nums = parts[0].split(".");
    var sufs = [];
    for (var i = 1; i < parts.length; i++) {
        var sm = /^([a-z]*)(\d*)$/.exec(parts[i]);
        if (sm) sufs.push([SUFFIX.hasOwnProperty(sm[1]) ? SUFFIX[sm[1]] : 0, sm[2] ? parseInt(sm[2], 10) : 0]);
    }
    return { nums: nums, sufs: sufs, rel: rel };
}

function cmpSeg(a, b) {
    var na = /^\d+$/.test(a), nb = /^\d+$/.test(b);
    if (na && nb) { var x = parseInt(a, 10), y = parseInt(b, 10); return x < y ? -1 : x > y ? 1 : 0; }
    // "1a" style letters, or anything else: compare leading number, then text
    var ma = /^(\d*)(.*)$/.exec(a), mb = /^(\d*)(.*)$/.exec(b);
    var ia = ma[1] === "" ? -1 : parseInt(ma[1], 10), ib = mb[1] === "" ? -1 : parseInt(mb[1], 10);
    if (ia !== ib) return ia < ib ? -1 : 1;
    return ma[2] < mb[2] ? -1 : ma[2] > mb[2] ? 1 : 0;
}

function vcmp(a, b) {
    var A = vparse(a), B = vparse(b);
    var n = Math.max(A.nums.length, B.nums.length);
    for (var i = 0; i < n; i++) {
        if (i >= A.nums.length) return -1;
        if (i >= B.nums.length) return 1;
        var c = cmpSeg(A.nums[i], B.nums[i]);
        if (c) return c;
    }
    var m = Math.max(A.sufs.length, B.sufs.length);
    for (var j = 0; j < m; j++) {
        var sa = j < A.sufs.length ? A.sufs[j] : [0, 0], sb = j < B.sufs.length ? B.sufs[j] : [0, 0];
        if (sa[0] !== sb[0]) return sa[0] < sb[0] ? -1 : 1;
        if (sa[1] !== sb[1]) return sa[1] < sb[1] ? -1 : 1;
    }
    return A.rel < B.rel ? -1 : A.rel > B.rel ? 1 : 0;
}

function short(v) { return String(v || "").replace(/-r0$/, ""); }

function satisfies(have, op, want) {
    var c = vcmp(have, want);
    if (op === ">=") return c >= 0;
    if (op === "<=") return c <= 0;
    if (op === ">") return c > 0;
    if (op === "<") return c < 0;
    if (op === "=") return c === 0;
    if (op === "~") return String(have).indexOf(String(want)) === 0;
    return true;
}

// is a package with these depends usable here? returns "" when it is, else a short reason
function incompatible(deps, env) {
    if (!deps) return "";
    var toks = String(deps).split(/\s+/);
    var lo = "", hi = "", failed = false;
    for (var i = 0; i < toks.length; i++) {
        var t = toks[i];
        if (!t) continue;
        var neg = t.charAt(0) === "!";
        if (neg) t = t.slice(1);
        var m = /^([^<>=~]+)(>=|<=|<|>|=|~)?(.*)$/.exec(t);
        if (!m) continue;
        var name = m[1], op = m[2] || "", ver = m[3] || "";
        if (DEVICES.indexOf(name) >= 0 && env.device) {
            if (neg && name === env.device) return "Not made for this tablet";
            if (!neg && !op && name !== env.device) return "Made for another reMarkable";
        }
        if (name === "remarkable-os" && op && !neg) {
            if (op === ">=" || op === ">" || op === "=" || op === "~") lo = ver;
            if (op === "<" || op === "<=" || op === "=") hi = op === "<" ? below(ver) : ver;
            if (env.os && !satisfies(env.os, op, ver)) failed = true;
        }
    }
    if (!failed) return "";
    if (lo && hi) return "Made for reMarkable " + (lo === hi ? lo : lo + "–" + hi);
    if (hi) return "Made for reMarkable " + hi + " and older";
    return "Needs reMarkable " + lo + " or newer";
}

// "3.29" -> "3.28": the last release line under an exclusive upper bound
function below(v) {
    var m = /^(\d+)\.(\d+)$/.exec(v);
    if (m && +m[2] > 0) return m[1] + "." + (+m[2] - 1);
    return "before " + v;
}

// ---------------------------------------------------------------- snapshot
function parseSnapshot(text) {
    var s = { have: "", arch: "", repos: [], avail: [], installed: {}, world: {}, checked: 0, now: 0, job: null };
    var lines = String(text || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var f = lines[i].split("\t");
        switch (f[0]) {
        case "HAVE": s.have = f[1]; break;
        case "ARCH": s.arch = f[1]; break;
        case "REPO": s.repos.push({ tag: f[1] === "-" ? "" : f[1], url: f[2] || "", desc: f[3] || "" }); break;
        case "A": s.avail.push({ repo: f[1], name: f[2], v: f[3], desc: f[4] || "", deps: f[5] || "", url: f[6] || "" }); break;
        case "I": s.installed[f[1]] = { name: f[1], v: f[2], desc: f[3] || "", deps: f[4] || "", url: f[5] || "" }; break;
        case "W": {
            var w = f[1] || "";
            var name = w.replace(/[@<>=~].*$/, "");
            var at = /@([A-Za-z0-9_-]+)/.exec(w);
            s.world[name] = { entry: w, tag: at ? at[1] : "" };
            break;
        }
        case "CHECKED": s.checked = parseInt(f[1], 10) || 0; break;
        case "NOW": s.now = parseInt(f[1], 10) || 0; break;
        case "JOB": s.job = parseJob(f); break;
        case "ALIVE": if (s.job) s.job.alive = f[1] === "1"; break;
        case "SEEN": if (s.job) s.job.seen = true; break;
        }
    }
    return s;
}

// JOB  queued|running|done  id  action  pkgs  [rc  end  restart] / [start]
function parseJob(f) {
    var j = { state: f[1], id: parseInt(f[2], 10) || 0, action: f[3] || "", pkgs: f[4] ? f[4].split(" ").filter(function (x) { return x; }) : [],
              rc: -1, end: 0, restart: false, alive: false, seen: false };
    if (j.state === "done") { j.rc = parseInt(f[5], 10); j.end = parseInt(f[6], 10) || 0; j.restart = f[7] === "1"; }
    return j;
}

function parsePoll(text) {
    var at = text.indexOf("@@LOG\n");
    var head = at >= 0 ? text.slice(0, at) : text;
    var log = at >= 0 ? text.slice(at + 6) : "";
    var s = parseSnapshot(head);
    return { job: s.job, now: s.now, log: cleanLog(log) };
}

function cleanLog(t) {
    return String(t || "").replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").replace(/\r(?!\n)/g, "\n");
}

// "(2/3) Upgrading nave (3.0.0-r0 -> 3.1.0-r0)" -> steps for the progress list
function steps(log) {
    var out = [];
    var re = /^\((\d+)\/(\d+)\) (Installing|Upgrading|Downgrading|Purging|Removing|Replacing|Reinstalling|Updating pinning) (\S+)(?: \((.*)\))?/;
    var lines = String(log || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var m = re.exec(lines[i]);
        if (m) out.push({ n: +m[1], of: +m[2], verb: m[3], name: m[4], ver: (m[5] || "").replace(/-r0\b/g, "").replace("->", "→") });
    }
    return out;
}

// ---------------------------------------------------------------- model
function repoLabel(r) {
    if (r.tag === "dakota" || r.desc === DAKOTA_DESC || r.url.indexOf("dakota86005") >= 0) return "Dakota’s mods";
    if (r.desc === "vellum" || /vellum/i.test(r.url) || /vellum/i.test(r.desc)) return "Vellum";
    if (r.desc) return r.desc;
    var m = /^https?:\/\/([^\/]+)/.exec(r.url);
    return m ? m[1] : r.url;
}

function prettyName(n) {
    return String(n).split("-").map(function (w) { return w ? w.charAt(0).toUpperCase() + w.slice(1) : w; }).join(" ");
}

function homeText(u) { return String(u || "").replace(/^https?:\/\//, "").replace(/\/$/, ""); }

function depNames(deps) {
    var out = [];
    String(deps || "").split(/\s+/).forEach(function (t) {
        if (!t || t.charAt(0) === "!") return;
        var n = t.replace(/[<>=~].*$/, "");
        if (VIRTUAL.indexOf(n) < 0 && n.indexOf("/") < 0 && n.indexOf(":") < 0) out.push(n);
    });
    return out;
}

function build(s) {
    var env = { os: "", device: "" };
    if (s.installed["remarkable-os"]) env.os = String(s.installed["remarkable-os"].v).replace(/-r\d+$/, "");
    for (var d = 0; d < DEVICES.length; d++) if (s.installed[DEVICES[d]]) env.device = DEVICES[d];

    var repos = [];
    var byUrl = {};
    s.repos.forEach(function (r) {
        if (!/^https?:\/\//.test(r.url)) return;
        var rr = { tag: r.tag, url: r.url, desc: r.desc, label: repoLabel(r), count: 0, loaded: false };
        repos.push(rr); byUrl[r.url] = rr;
    });

    repos.sort(function (a, b) { return (b.tag === "dakota" ? 1 : 0) - (a.tag === "dakota" ? 1 : 0); });

    // best usable (and newest overall) version of each name in each repo
    var best = {};
    s.avail.forEach(function (a) {
        var r = byUrl[a.repo];
        if (!r || VIRTUAL.indexOf(a.name) >= 0) return;
        r.loaded = true;
        var key = a.repo + "\n" + a.name;
        var b = best[key] || (best[key] = { repo: r, name: a.name, ok: null, newest: null });
        a.why = incompatible(a.deps, env);
        if (!b.newest || vcmp(a.v, b.newest.v) > 0) b.newest = a;
        if (!a.why && (!b.ok || vcmp(a.v, b.ok.v) > 0)) b.ok = a;
    });

    // who needs what, among installed packages
    var neededBy = {};
    Object.keys(s.installed).forEach(function (n) {
        depNames(s.installed[n].deps).forEach(function (dn) { (neededBy[dn] = neededBy[dn] || []).push(n); });
    });

    function candidatesFor(name, tag) {
        var out = [];
        repos.forEach(function (r) { if (r.tag === tag && best[r.url + "\n" + name]) out.push(best[r.url + "\n" + name]); });
        return out;
    }

    var installed = [], updates = 0;
    Object.keys(s.installed).sort().forEach(function (n) {
        if (VIRTUAL.indexOf(n) >= 0) return;
        var i = s.installed[n];
        var w = s.world[n];
        var tag = w ? w.tag : "";
        var cands = candidatesFor(n, tag);
        var avail = null, repo = null;
        cands.forEach(function (c) { if (c.ok && (!avail || vcmp(c.ok.v, avail.v) > 0)) { avail = c.ok; repo = c.repo; } });
        if (!repo && cands.length) repo = cands[0].repo;
        if (!repo) repos.forEach(function (r) { if (r.tag === tag && !repo && tag) repo = r; });
        var up = !!(avail && vcmp(avail.v, i.v) > 0);
        if (up) updates++;
        installed.push({
            name: n, title: prettyName(n), v: i.v, desc: i.desc || (avail ? avail.desc : ""), home: i.url || (avail ? avail.url : ""),
            deps: i.deps, explicit: !!w, tag: tag, source: repo ? repo.label : (tag ? "@" + tag : ""), repoUrl: repo ? repo.url : "",
            installed: true, newV: up ? avail.v : "", update: up, why: "", neededBy: (neededBy[n] || []).slice().sort(),
            installName: n + (tag ? "@" + tag : "")
        });
    });
    // updates first, then your own picks, then what came along as dependencies
    installed.sort(function (a, b) {
        var ka = (a.update ? 0 : 2) + (a.explicit ? 0 : 1), kb = (b.update ? 0 : 2) + (b.explicit ? 0 : 1);
        return ka !== kb ? ka - kb : (a.name < b.name ? -1 : 1);
    });

    var discover = [];
    Object.keys(best).forEach(function (k) {
        var b = best[k];
        var a = b.ok || b.newest;
        var inst = s.installed[b.name];
        var w = s.world[b.name];
        var here = !!inst && (w ? w.tag === b.repo.tag : !b.repo.tag);
        b.repo.count++;
        discover.push({
            name: b.name, title: prettyName(b.name), v: a.v, desc: a.desc, home: a.url, deps: a.deps,
            source: b.repo.label, repoUrl: b.repo.url, tag: b.repo.tag, installed: here, otherInstalled: !!inst && !here,
            instV: inst ? inst.v : "", why: b.ok ? "" : b.newest.why, update: here && !!b.ok && vcmp(b.ok.v, inst.v) > 0,
            newV: b.ok ? b.ok.v : "", explicit: !!w, neededBy: (neededBy[b.name] || []).slice().sort(),
            installName: b.name + (b.repo.tag ? "@" + b.repo.tag : "")
        });
    });
    discover.sort(function (a, b) { return a.name < b.name ? -1 : a.name > b.name ? 1 : (a.source < b.source ? -1 : 1); });

    return { env: env, repos: repos, installed: installed, discover: discover, updates: updates };
}

function clock(epoch) {
    var d = new Date(epoch * 1000);
    var h = d.getHours(), m = d.getMinutes();
    return (h % 12 || 12) + ":" + (m < 10 ? "0" : "") + m + (h < 12 ? " AM" : " PM");
}

function when(epoch, now) {
    if (!epoch) return "never";
    var age = now - epoch;
    if (age < 90) return "just now";
    var d = new Date(epoch * 1000), n = new Date(now * 1000);
    if (d.toDateString() === n.toDateString()) return "today at " + clock(epoch);
    var y = new Date((now - 86400) * 1000);
    if (d.toDateString() === y.toDateString()) return "yesterday at " + clock(epoch);
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    return months[d.getMonth()] + " " + d.getDate();
}

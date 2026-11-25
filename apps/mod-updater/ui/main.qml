// Mods: install, update and remove Vellum packages on the tablet (AppLoad app).
// The backend (backend/entry + agent.sh) runs vellum; changes run as their own systemd unit,
// so a mod that restarts the reMarkable UI can't cut an install short.
import QtQuick 2.15
import net.asivery.AppLoad 1.0
import "logic.js" as L

Rectangle {
    id: app
    anchors.fill: parent
    color: "white"

    // ---- AppLoad contract
    signal close
    function unloading() { pingTimer.stop(); pollTimer.stop(); }

    // ---- look
    readonly property real u: width / 1620
    readonly property real ch: height / u                  // canvas height in design px
    readonly property string serif: fRegular.name || "serif"
    readonly property color ink: "#000000"
    readonly property color soft: "#555555"
    readonly property int margin: 96

    FontLoader { id: fRegular; source: "fonts/Serif-Regular.ttf" }
    FontLoader { id: fSemi; source: "fonts/Serif-SemiBold.ttf" }
    FontLoader { id: fItalic; source: "fonts/Serif-Italic.ttf" }

    // ---- state
    property bool ready: false
    property int pings: 0
    property int seq: 0
    property var pending: ({})
    property var snap: null
    property var model: ({ env: {}, repos: [], installed: [], discover: [], updates: 0 })
    property int now: 0
    property bool loading: true
    property bool refreshing: false
    property string refreshNote: ""
    property string tab: "installed"           // "installed" | "discover"
    property string source: ""                 // discover filter: "" = every source, else repo url
    property bool sourcePicked: false          // set once the person picks a source themselves
    property bool showOther: false             // discover: also list mods made for other OS versions
    property int page: 0
    property var detail: null                  // row shown in the detail sheet
    property bool confirmRemove: false
    property string message: ""
    // job
    property var job: null
    property string jobLog: ""
    property bool jobOpen: false
    property bool jobFullLog: false
    property string jobTitle: ""
    property int jobSeenAt: 0
    property int pollFails: 0

    // =========================================================== backend
    AppLoad {
        id: backend
        applicationID: "mod-updater"
        onMessageReceived: (type, contents) => app.fromBackend(type, contents)
    }

    function request(args, done, chunk) {
        app.seq++;
        var id = "r" + app.seq;
        app.pending[id] = { out: "", done: done, chunk: chunk };
        backend.sendMessage(1, id + "\n" + args.join("\n"));
        return id;
    }

    function fromBackend(type, contents) {
        var nl = contents.indexOf("\n");
        if (nl < 0) return;
        var id = contents.slice(0, nl), body = contents.slice(nl + 1);
        var p = app.pending[id];
        if (!p) return;
        if (type === 2) {
            p.out += body;
            if (p.chunk) p.chunk(body);
        } else if (type === 3) {
            delete app.pending[id];
            if (p.done) p.done(parseInt(body, 10), p.out);
        }
    }

    // AppLoad drops messages sent before the backend has connected, so knock until it answers.
    Timer {
        id: pingTimer
        interval: 700; repeat: true; running: true; triggeredOnStart: true
        onTriggered: {
            if (app.ready) { stop(); return; }
            app.pings++;
            if (app.pings > 20) {
                stop();
                app.loading = false;
                app.message = "The Mods helper didn’t start. Close Mods and open it again. If it still doesn’t work, reinstall it with: vellum add mod-updater@dakota";
                return;
            }
            app.request(["ping"], function (rc, out) {
                if (app.ready) return;
                app.ready = true;
                pingTimer.stop();
                app.loadSnapshot(true);
            });
        }
    }

    function loadSnapshot(first) {
        app.request(["snapshot"], function (rc, out) {
            var s = L.parseSnapshot(out);
            app.snap = s;
            app.now = s.now;
            app.model = L.build(s);
            app.loading = false;
            if (!app.sourcePicked) {
                var mine = app.model.repos.filter(function (r) { return r.tag === "dakota" && r.count > 0; });
                if (mine.length) app.source = mine[0].url;
            }
            app.clampPage();
            if (app.detail) app.detail = app.findRow(app.detail.name, app.detail.repoUrl);
            if (first) {
                app.resumeJob(s.job);
                if (s.have === "vellum" && (!s.checked || s.now - s.checked > 6 * 3600) && !app.jobBusy()) app.refresh();
            }
        });
    }

    function refresh() {
        if (app.refreshing || !app.ready) return;
        app.refreshing = true;
        app.refreshNote = "";
        app.request(["refresh"], function (rc, out) {
            app.refreshing = false;
            if (rc === 3) app.refreshNote = "Vellum isn’t installed on this tablet.";
            else if (rc === 4) app.refreshNote = "Couldn’t reach the package servers. Is Wi‑Fi on?";
            else if (rc === 5) app.refreshNote = "One of the package lists couldn’t be read. Showing the last copy.";
            else if (rc !== 0) app.refreshNote = "Checking didn’t finish (" + rc + ").";
            app.loadSnapshot(false);
        });
    }

    // =========================================================== jobs
    function jobBusy() { return !!app.job && (app.job.state === "queued" || (app.job.state === "running" && app.job.alive)); }

    function describe(action, pkgs) {
        var names = pkgs.map(function (p) { return L.prettyName(p.replace(/@.*$/, "")); });
        var what = names.length === 1 ? names[0] : names.length + " mods";
        if (action === "add") return "Installing " + what;
        if (action === "del") return "Removing " + what;
        if (action === "purge") return "Removing " + what + " and its data";
        return names.length ? "Updating " + what : "Updating everything";
    }

    function startJob(action, pkgs) {
        if (app.jobBusy()) { app.jobOpen = true; return; }
        app.detail = null;
        app.confirmRemove = false;
        app.request(["job", action].concat(pkgs), function (rc, out) {
            if (rc !== 0) { app.message = out.trim() || ("That didn’t start (" + rc + ")."); return; }
            app.job = { state: "queued", id: Math.floor(Date.now() / 1000), action: action, pkgs: pkgs, rc: -1, alive: true, restart: false, seen: false };
            app.jobTitle = app.describe(action, pkgs);
            app.jobLog = "";
            app.jobFullLog = false;
            app.jobOpen = true;
            app.pollFails = 0;
            pollTimer.start();
        });
    }

    function resumeJob(j) {
        if (!j) return;
        app.job = j;
        app.jobTitle = app.describe(j.action, j.pkgs);
        if (app.jobBusy()) { app.jobOpen = true; pollTimer.start(); return; }
        if (!j.seen) { app.jobOpen = true; app.poll(); }       // finished (or cut off) while Mods was closed
    }

    function poll() {
        app.request(["jobpoll"], function (rc, out) {
            var p = L.parsePoll(out);
            if (p.now) app.now = p.now;
            app.jobLog = p.log;
            if (!p.job) return;
            app.job = p.job;
            if (p.job.state === "done") {
                pollTimer.stop();
                app.loadSnapshot(false);
            } else if (!p.job.alive && (p.job.state === "running" || app.now - p.job.id > 25)) {
                pollTimer.stop();                                 // cut off, or never started
                app.loadSnapshot(false);
            }
        });
    }

    Timer { id: pollTimer; interval: 1500; repeat: true; onTriggered: app.poll() }

    function closeJob() {
        if (app.jobBusy()) { app.jobOpen = false; return; }
        app.request(["ack"]);
        if (app.job) app.job.seen = true;
        app.jobOpen = false;
        app.loadSnapshot(false);
    }

    // =========================================================== rows and pages
    function findRow(name, repoUrl) {
        var lists = [app.model.installed, app.model.discover];
        for (var l = 0; l < lists.length; l++)
            for (var i = 0; i < lists[l].length; i++)
                if (lists[l][i].name === name && (!repoUrl || lists[l][i].repoUrl === repoUrl || l === 0)) return lists[l][i];
        return null;
    }

    readonly property var rows: {
        var out = [];
        if (app.tab === "installed") {
            var ups = [], mine = [], deps = [];
            app.model.installed.forEach(function (r) { (r.update ? ups : r.explicit ? mine : deps).push(r); });
            if (ups.length) { out.push({ head: ups.length === 1 ? "1 update ready" : ups.length + " updates ready" }); out = out.concat(ups); }
            if (mine.length) { out.push({ head: "Installed" }); out = out.concat(mine); }
            if (deps.length) { out.push({ head: "Installed for other mods" }); out = out.concat(deps); }
        } else {
            app.model.discover.forEach(function (r) {
                if (app.source && r.repoUrl !== app.source) return;
                if (r.why && !app.showOther && !r.installed) return;
                out.push(r);
            });
        }
        return out;
    }
    readonly property int hiddenOther: {
        var n = 0;
        app.model.discover.forEach(function (r) { if ((!app.source || r.repoUrl === app.source) && r.why && !r.installed) n++; });
        return n;
    }

    readonly property int rowH: 240
    readonly property int headH: 96
    readonly property real listTop: 560
    readonly property real listBottom: app.ch - (app.tab === "discover" ? 260 : 170)
    readonly property var pages: {
        var avail = app.listBottom - app.listTop, out = [], cur = [], used = 0;
        for (var i = 0; i < app.rows.length; i++) {
            var r = app.rows[i], h = r.head ? app.headH : app.rowH;
            if (used + h > avail && cur.length) { out.push(cur); cur = []; used = 0; }
            if (r.head && used + app.headH + app.rowH > avail && cur.length) { out.push(cur); cur = []; used = 0; }
            cur.push(r); used += h;
        }
        if (cur.length) out.push(cur);
        return out;
    }
    function clampPage() { if (app.page >= app.pages.length) app.page = Math.max(0, app.pages.length - 1); }
    onTabChanged: page = 0
    onSourceChanged: page = 0
    onShowOtherChanged: page = 0

    readonly property var letters: {
        var seen = {}, out = [];
        for (var p = 0; p < app.pages.length; p++)
            for (var i = 0; i < app.pages[p].length; i++) {
                var r = app.pages[p][i];
                if (r.head) continue;
                var c = r.name.charAt(0).toUpperCase();
                if (!/[A-Z]/.test(c)) c = "#";
                if (!seen[c]) { seen[c] = true; out.push({ c: c, page: p }); }
            }
        return out;
    }

    // =========================================================== little parts
    component Label: Text {
        font.family: app.serif
        font.pixelSize: 36 * app.u
        color: app.ink
        textFormat: Text.PlainText
    }

    component Button: Rectangle {
        id: btn
        property string text: ""
        property bool filled: false
        property bool active: true
        property real fontSize: 34
        signal tapped
        width: Math.max(200 * app.u, lab.implicitWidth + 64 * app.u)
        height: 84 * app.u
        radius: 6 * app.u
        color: filled && active ? app.ink : "white"
        border.width: (active ? 3 : 2) * app.u
        border.color: active ? app.ink : app.soft
        Label {
            id: lab
            anchors.centerIn: parent
            text: btn.text
            font.family: app.serif; font.weight: Font.DemiBold
            font.pixelSize: btn.fontSize * app.u
            color: btn.filled && btn.active ? "white" : (btn.active ? app.ink : app.soft)
        }
        MouseArea { anchors.fill: parent; anchors.margins: -10 * app.u; enabled: btn.active; onClicked: btn.tapped() }
    }

    component Tab: Item {
        id: tb
        property string text: ""
        property bool active: false
        signal tapped
        width: tl.implicitWidth + 8 * app.u
        height: 90 * app.u
        Label {
            id: tl
            text: tb.text
            font.pixelSize: 46 * app.u
            font.family: app.serif
            font.weight: tb.active ? Font.DemiBold : Font.Normal
            color: tb.active ? app.ink : app.soft
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
        }
        Rectangle { visible: tb.active; anchors.bottom: parent.bottom; width: parent.width; height: 5 * app.u; color: app.ink }
        MouseArea { anchors.fill: parent; anchors.margins: -16 * app.u; onClicked: tb.tapped() }
    }

    component Chip: Rectangle {
        id: cp
        property string text: ""
        property bool active: false
        signal tapped
        width: cl.implicitWidth + 48 * app.u
        height: 64 * app.u
        radius: height / 2
        color: active ? app.ink : "white"
        border.width: 2 * app.u
        border.color: active ? app.ink : app.soft
        Label { id: cl; anchors.centerIn: parent; text: cp.text; font.pixelSize: 30 * app.u; color: cp.active ? "white" : app.ink }
        MouseArea { anchors.fill: parent; anchors.margins: -8 * app.u; onClicked: cp.tapped() }
    }

    // =========================================================== header
    Item {
        id: header
        x: app.margin * app.u
        width: (1620 - 2 * app.margin) * app.u
        y: 0
        height: 400 * app.u

        Label {
            id: eyebrow
            y: 92 * app.u
            text: "VELLUM · " + (app.model.env.os ? "REMARKABLE " + app.model.env.os : "REMARKABLE")
            font.pixelSize: 26 * app.u
            font.letterSpacing: 4 * app.u
            color: app.soft
        }
        Label {
            id: title
            anchors.top: eyebrow.bottom
            anchors.topMargin: 6 * app.u
            text: "Mods"
            font.family: app.serif; font.weight: Font.DemiBold
            font.pixelSize: 112 * app.u
        }
        Label {
            id: status
            anchors.top: title.bottom
            anchors.topMargin: 4 * app.u
            width: parent.width - checkBtn.width - 40 * app.u
            font.family: app.serif
            font.italic: true
            font.pixelSize: 36 * app.u
            color: app.soft
            elide: Text.ElideRight
            text: {
                if (app.loading) return "Opening…";
                if (!app.snap) return "";
                if (app.snap.have !== "vellum") return "Vellum isn’t installed on this tablet.";
                if (app.refreshing) return "Checking for updates…";
                if (app.refreshNote) return app.refreshNote;
                var t = "Checked " + L.when(app.snap.checked, app.now);
                if (app.model.updates) t += " · " + (app.model.updates === 1 ? "1 update ready" : app.model.updates + " updates ready");
                else if (app.snap.checked) t += " · everything is up to date";
                return t;
            }
        }
        Button {
            id: checkBtn
            anchors.right: parent.right
            anchors.verticalCenter: status.verticalCenter
            text: app.refreshing ? "Checking…" : "Check now"
            active: app.ready && !app.refreshing
            onTapped: app.refresh()
        }
        Item {
            anchors.right: parent.right
            y: 70 * app.u
            width: closeLab.implicitWidth
            height: 70 * app.u
            Label { id: closeLab; anchors.verticalCenter: parent.verticalCenter; text: "Close ×"; font.pixelSize: 34 * app.u; color: app.soft }
            MouseArea { anchors.fill: parent; anchors.margins: -24 * app.u; onClicked: app.close() }
        }
    }

    // ---- tabs
    Item {
        id: tabs
        x: app.margin * app.u
        y: 404 * app.u
        width: (1620 - 2 * app.margin) * app.u
        height: 90 * app.u
        Row {
            spacing: 64 * app.u
            Tab {
                text: "Installed"
                active: app.tab === "installed"
                onTapped: app.tab = "installed"
            }
            Tab {
                text: "Discover"
                active: app.tab === "discover"
                onTapped: app.tab = "discover"
            }
        }
        Button {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: app.tab === "installed" && app.model.updates > 0
            filled: true
            text: app.model.updates === 1 ? "Update" : "Update all " + app.model.updates
            onTapped: app.startJob("upgrade", [])
        }
        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 16 * app.u
            visible: app.tab === "discover"
            Repeater {
                model: app.model.repos
                delegate: Chip {
                    required property var modelData
                    visible: modelData.count > 0
                    text: modelData.label
                    active: app.source === modelData.url
                    onTapped: { app.source = modelData.url; app.sourcePicked = true; }
                }
            }
            Chip { text: "All"; active: app.source === ""; onTapped: { app.source = ""; app.sourcePicked = true; } }
        }
        Rectangle { anchors.top: parent.bottom; width: parent.width; height: 2 * app.u; color: app.ink }
    }

    // =========================================================== list
    Column {
        id: list
        x: app.margin * app.u
        y: app.listTop * app.u
        width: (1620 - 2 * app.margin) * app.u
        Repeater {
            model: app.pages.length ? app.pages[Math.min(app.page, app.pages.length - 1)] : []
            delegate: Loader {
                required property var modelData
                width: list.width
                sourceComponent: modelData.head ? headRow : pkgRow
                onLoaded: item.row = modelData
            }
        }
    }

    Component {
        id: headRow
        Item {
            property var row: null
            width: list.width
            height: app.headH * app.u
            Label {
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 18 * app.u
                text: row ? row.head.toUpperCase() : ""
                font.pixelSize: 28 * app.u
                font.letterSpacing: 4 * app.u
                color: app.soft
            }
        }
    }

    Component {
        id: pkgRow
        Item {
            id: pr
            property var row: null
            width: list.width
            height: app.rowH * app.u
            MouseArea { anchors.fill: parent; onClicked: { app.detail = pr.row; app.confirmRemove = false; } }
            Label {
                id: nm
                y: 28 * app.u
                width: Math.min(implicitWidth, parent.width - act.width - 60 * app.u)
                elide: Text.ElideRight
                text: pr.row ? pr.row.title : ""
                font.family: app.serif; font.weight: Font.DemiBold
                font.pixelSize: 46 * app.u
            }
            Label {
                id: meta
                anchors.top: nm.bottom
                anchors.topMargin: 2 * app.u
                width: parent.width - act.width - 60 * app.u
                elide: Text.ElideRight
                font.pixelSize: 26 * app.u
                font.letterSpacing: 2 * app.u
                color: app.soft
                text: {
                    var r = pr.row;
                    if (!r) return "";
                    var bits = [r.name];
                    if (r.update) bits.push(L.short(r.instV || r.v) + " → " + L.short(r.newV));
                    else bits.push(L.short(r.v));
                    if (r.source && (app.tab === "installed" || app.source === "")) bits.push(r.source.toUpperCase());
                    return bits.join("   ·   ");
                }
            }
            Label {
                anchors.top: meta.bottom
                anchors.topMargin: 8 * app.u
                width: parent.width - act.width - 60 * app.u
                text: pr.row ? pr.row.desc : ""
                font.family: app.serif
                font.italic: true
                font.pixelSize: 32 * app.u
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
                lineHeight: 0.95
            }
            Item {
                id: act
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 250 * app.u
                height: 90 * app.u
                Button {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !!pr.row && (pr.row.update || (!pr.row.installed && !pr.row.otherInstalled && !pr.row.why))
                    filled: !!pr.row && pr.row.update
                    text: pr.row && pr.row.update ? "Update" : "Install"
                    active: !app.jobBusy()
                    onTapped: {
                        if (pr.row.update) app.startJob("upgrade", [pr.row.name]);
                        else app.startJob("add", [pr.row.installName]);
                    }
                }
                Label {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    horizontalAlignment: Text.AlignRight
                    visible: !!pr.row && !pr.row.update && (pr.row.installed || pr.row.otherInstalled || !!pr.row.why)
                    wrapMode: Text.WordWrap
                    font.family: app.serif
                    font.italic: true
                    font.pixelSize: 30 * app.u
                    color: app.soft
                    text: {
                        var r = pr.row;
                        if (!r) return "";
                        if (app.tab === "installed") return "";
                        if (r.installed) return "Installed";
                        if (r.otherInstalled) return "Installed from another source";
                        return r.why;
                    }
                }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2 * app.u; color: app.soft }
        }
    }

    // ---- empty and loading states
    Label {
        x: app.margin * app.u
        y: (app.listTop + 60) * app.u
        width: (1620 - 2 * app.margin) * app.u
        visible: !app.loading && app.rows.length === 0
        wrapMode: Text.WordWrap
        font.family: app.serif
        font.italic: true
        font.pixelSize: 40 * app.u
        color: app.soft
        text: {
            if (!app.snap) return "";
            if (app.snap.have !== "vellum") return "Mods needs Vellum. Install it from reManager, then open Mods again.";
            if (app.tab === "installed") return "Nothing is installed through Vellum yet. Have a look in Discover.";
            if (!app.snap.checked) return "Tap Check now to fetch the lists of mods.";
            if (app.hiddenOther) return "Nothing here is made for this version of reMarkable.";
            return "No mods to show from this source.";
        }
    }

    // ---- foot: letters, other versions, pages
    Item {
        id: foot
        x: app.margin * app.u
        width: (1620 - 2 * app.margin) * app.u
        y: (app.listBottom + 10) * app.u
        height: (app.ch - app.listBottom - 10) * app.u

        Flow {
            id: letterRow
            visible: app.tab === "discover" && app.pages.length > 2
            width: parent.width
            spacing: 2 * app.u
            Repeater {
                model: app.letters
                delegate: Item {
                    required property var modelData
                    width: 50 * app.u
                    height: 60 * app.u
                    Label {
                        anchors.centerIn: parent
                        text: modelData.c
                        font.pixelSize: 32 * app.u
                        font.family: app.serif
                        font.weight: modelData.page === app.page ? Font.DemiBold : Font.Normal
                        color: modelData.page === app.page ? app.ink : app.soft
                    }
                    Rectangle {
                        visible: modelData.page === app.page
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 30 * app.u; height: 3 * app.u; color: app.ink
                    }
                    MouseArea { anchors.fill: parent; onClicked: app.page = modelData.page }
                }
            }
        }

        Item {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 60 * app.u
            width: parent.width
            height: 84 * app.u
            Button {
                anchors.left: parent.left
                visible: app.pages.length > 1
                active: app.page > 0
                text: "‹  Previous"
                onTapped: app.page--
            }
            Label {
                anchors.centerIn: parent
                font.family: app.serif
                font.italic: true
                font.pixelSize: 32 * app.u
                color: app.soft
                text: {
                    var t = app.pages.length > 1 ? "Page " + (app.page + 1) + " of " + app.pages.length : "";
                    if (app.tab === "discover" && app.hiddenOther)
                        t += (t ? "   ·   " : "") + (app.showOther ? "Hide " : "Show ") + app.hiddenOther + " for other versions";
                    return t;
                }
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -20 * app.u
                    enabled: app.tab === "discover" && app.hiddenOther > 0
                    onClicked: app.showOther = !app.showOther
                }
            }
            Button {
                anchors.right: parent.right
                visible: app.pages.length > 1
                active: app.page < app.pages.length - 1
                text: "Next  ›"
                onTapped: app.page++
            }
        }
    }

    // ---- quiet message line
    Rectangle {
        visible: app.message !== ""
        x: app.margin * app.u
        width: (1620 - 2 * app.margin) * app.u
        y: (app.listTop - 40) * app.u
        height: msg.implicitHeight + 50 * app.u
        color: "white"
        border.width: 3 * app.u
        border.color: app.ink
        z: 5
        Label {
            id: msg
            x: 30 * app.u; width: parent.width - 140 * app.u
            anchors.verticalCenter: parent.verticalCenter
            wrapMode: Text.WordWrap
            text: app.message
            font.pixelSize: 34 * app.u
        }
        Label { anchors.right: parent.right; anchors.rightMargin: 30 * app.u; anchors.verticalCenter: parent.verticalCenter; text: "×"; font.pixelSize: 50 * app.u }
        MouseArea { anchors.fill: parent; onClicked: app.message = "" }
    }

    // =========================================================== detail sheet
    MouseArea {
        anchors.fill: parent
        visible: app.detail !== null && !app.jobOpen
        z: 9
        onClicked: { app.detail = null; app.confirmRemove = false; }
    }
    Rectangle {
        id: sheet
        visible: app.detail !== null && !app.jobOpen
        z: 10
        width: parent.width
        anchors.bottom: parent.bottom
        height: sheetCol.implicitHeight + 150 * app.u
        color: "white"
        Rectangle { width: parent.width; height: 4 * app.u; color: app.ink }
        MouseArea { anchors.fill: parent }     // keep taps inside the sheet
        readonly property var r: app.detail || ({})
        Column {
            id: sheetCol
            x: app.margin * app.u
            y: 70 * app.u
            width: (1620 - 2 * app.margin) * app.u
            spacing: 18 * app.u
            Label {
                text: (sheet.r.source || "").toUpperCase()
                font.pixelSize: 26 * app.u
                font.letterSpacing: 4 * app.u
                color: app.soft
            }
            Label { text: sheet.r.title || ""; font.family: app.serif; font.weight: Font.DemiBold; font.pixelSize: 76 * app.u; width: parent.width; elide: Text.ElideRight }
            Label {
                width: parent.width
                wrapMode: Text.WordWrap
                text: sheet.r.desc || ""
                font.family: app.serif
                font.italic: true
                font.pixelSize: 38 * app.u
            }
            Item { width: 1; height: 6 * app.u }
            Repeater {
                model: {
                    var r = sheet.r, out = [];
                    if (!r.name) return out;
                    out.push(["Package", r.installName || r.name]);
                    if (r.installed || r.instV) out.push(["Installed", L.short(r.instV || r.v) + (r.update ? "   →   " + L.short(r.newV) + " ready" : "")]);
                    else out.push(["Version", L.short(r.v)]);
                    if (r.why) out.push(["Note", r.why]);
                    var needs = L.depNames(r.deps);
                    if (needs.length) out.push(["Needs", needs.join(", ")]);
                    if (r.neededBy && r.neededBy.length) out.push(["Used by", r.neededBy.join(", ")]);
                    if (r.home) out.push(["Home", L.homeText(r.home)]);
                    return out;
                }
                delegate: Row {
                    required property var modelData
                    spacing: 24 * app.u
                    Label { width: 210 * app.u; text: modelData[0]; font.pixelSize: 30 * app.u; color: app.soft; font.letterSpacing: 1 * app.u }
                    Label { width: sheetCol.width - 234 * app.u; text: modelData[1]; font.pixelSize: 32 * app.u; wrapMode: Text.WrapAnywhere }
                }
            }
            Item { width: 1; height: 20 * app.u }
            Label {
                visible: app.confirmRemove
                width: parent.width
                wrapMode: Text.WordWrap
                font.pixelSize: 32 * app.u
                text: {
                    var r = sheet.r;
                    var t = "Remove " + (r.title || "") + "? ";
                    if (r.neededBy && r.neededBy.length) t += "Vellum will keep it while " + r.neededBy.join(", ") + (r.neededBy.length === 1 ? " needs" : " need") + " it. ";
                    t += "“Remove” keeps its settings; “Remove with data” deletes them too.";
                    return t;
                }
            }
            Row {
                spacing: 28 * app.u
                Button {
                    visible: !!sheet.r.name && (sheet.r.update || (!sheet.r.installed && !sheet.r.otherInstalled && !sheet.r.why))
                    filled: true
                    active: !app.jobBusy()
                    text: sheet.r.update ? "Update to " + L.short(sheet.r.newV) : "Install"
                    onTapped: sheet.r.update ? app.startJob("upgrade", [sheet.r.name]) : app.startJob("add", [sheet.r.installName])
                }
                Button {
                    visible: !!sheet.r.installed && !!sheet.r.explicit && !app.confirmRemove
                    active: !app.jobBusy()
                    text: "Remove…"
                    onTapped: app.confirmRemove = true
                }
                Button {
                    visible: app.confirmRemove
                    filled: true
                    text: "Remove"
                    onTapped: app.startJob("del", [sheet.r.name])
                }
                Button {
                    visible: app.confirmRemove
                    text: "Remove with data"
                    onTapped: app.startJob("purge", [sheet.r.name])
                }
                Button {
                    text: app.confirmRemove ? "Keep it" : "Close"
                    onTapped: { if (app.confirmRemove) app.confirmRemove = false; else app.detail = null; }
                }
            }
        }
    }

    // =========================================================== job sheet
    MouseArea { anchors.fill: parent; visible: app.jobOpen; z: 19 }
    Rectangle {
        id: jobSheet
        visible: app.jobOpen
        z: 20
        width: parent.width
        anchors.bottom: parent.bottom
        height: Math.max(1100 * app.u, jobCol.implicitHeight + 200 * app.u)
        color: "white"
        Rectangle { width: parent.width; height: 4 * app.u; color: app.ink }
        readonly property var j: app.job || ({})
        readonly property bool busy: app.jobBusy()
        readonly property bool cutOff: !busy && j.state !== "done"
        readonly property bool ok: j.state === "done" && j.rc === 0
        readonly property var st: L.steps(app.jobLog)
        Column {
            id: jobCol
            x: app.margin * app.u
            y: 80 * app.u
            width: (1620 - 2 * app.margin) * app.u
            spacing: 22 * app.u
            Label {
                text: jobSheet.busy ? "WORKING" : jobSheet.ok ? "DONE" : jobSheet.cutOff ? "STOPPED" : "DIDN’T FINISH"
                font.pixelSize: 26 * app.u
                font.letterSpacing: 4 * app.u
                color: app.soft
            }
            Label { text: app.jobTitle; font.family: app.serif; font.weight: Font.DemiBold; font.pixelSize: 72 * app.u; width: parent.width; wrapMode: Text.WordWrap }
            Label {
                width: parent.width
                wrapMode: Text.WordWrap
                font.family: app.serif
                font.italic: true
                font.pixelSize: 36 * app.u
                color: app.soft
                text: {
                    var j = jobSheet.j;
                    if (jobSheet.busy) return "This keeps going even if you close Mods. Some mods restart the screen when they’re done; open Mods again afterwards to see how it went.";
                    if (jobSheet.cutOff) return "This change stopped before it finished, probably because the tablet restarted. Tap Check now and try again.";
                    var at = j.end ? "Finished " + L.when(j.end, app.now) + ". " : "";
                    if (jobSheet.ok && j.restart) return at + "The screen restarts in a few seconds to load the change. Mods will close; that’s expected.";
                    if (jobSheet.ok) return at + "All set.";
                    return at + "Vellum stopped with an error. Its last words are below.";
                }
            }
            Item { width: 1; height: 10 * app.u }
            Repeater {
                model: jobSheet.st
                delegate: Row {
                    required property var modelData
                    required property int index
                    spacing: 26 * app.u
                    readonly property bool current: jobSheet.busy && index === jobSheet.st.length - 1
                    Label { width: 50 * app.u; text: parent.current ? "…" : "✓"; font.pixelSize: 38 * app.u; font.family: app.serif; font.weight: Font.DemiBold }
                    Label {
                        width: jobCol.width - 80 * app.u
                        elide: Text.ElideRight
                        font.pixelSize: 38 * app.u
                        text: modelData.verb + " " + L.prettyName(modelData.name) + (modelData.ver ? "   " + modelData.ver : "")
                    }
                }
            }
            Rectangle {
                visible: app.jobFullLog || (!jobSheet.busy && !jobSheet.ok) || (jobSheet.st.length === 0 && app.jobLog.length > 0)
                width: parent.width
                height: Math.min(logText.implicitHeight, 620 * app.u) + 40 * app.u
                color: "white"
                border.width: 2 * app.u
                border.color: app.soft
                clip: true
                Text {
                    id: logText
                    x: 24 * app.u
                    width: parent.width - 48 * app.u
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 20 * app.u
                    textFormat: Text.PlainText
                    wrapMode: Text.WrapAnywhere
                    font.family: "monospace"
                    font.pixelSize: 24 * app.u
                    color: app.ink
                    text: {
                        var lines = app.jobLog.replace(/\n+$/, "").split("\n");
                        return lines.slice(-24).join("\n");
                    }
                }
            }
            Item { width: 1; height: 20 * app.u }
            Row {
                spacing: 28 * app.u
                Button {
                    filled: !jobSheet.busy
                    text: jobSheet.busy ? "Hide" : "Done"
                    onTapped: app.closeJob()
                }
                Button {
                    text: app.jobFullLog ? "Hide details" : "Show details"
                    visible: app.jobLog.length > 0
                    onTapped: app.jobFullLog = !app.jobFullLog
                }
            }
        }
    }
}

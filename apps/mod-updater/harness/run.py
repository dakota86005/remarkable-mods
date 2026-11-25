# Offscreen harness for the Mods app. Builds a fake tablet (mkenv.py), runs the real backend
# (bridge under qemu-aarch64 when available, else a host build) behind a mock AppLoad endpoint,
# loads ui/main.qml at 1620x2160 and runs a scenario script that can tap and take screenshots.
#   python3 harness/run.py <scenario.py> <outdir> [velbuild_dir]
import os, sys, socket, struct, subprocess, threading, time, shutil
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
os.environ['QT_QUICK_BACKEND'] = 'software'
HERE = os.path.dirname(os.path.abspath(__file__)); APP = os.path.dirname(HERE)
OUT = os.path.abspath(sys.argv[2]); os.makedirs(OUT, exist_ok=True)
ENV = os.path.join(OUT, 'env')
port = str(8700 + os.getpid() % 200)
os.environ['MU_PORT'] = port
subprocess.check_call([sys.executable, os.path.join(HERE, 'mkenv.py'), ENV] + sys.argv[3:4])
www = subprocess.Popen([sys.executable, '-m', 'http.server', port, '--bind', '127.0.0.1'], cwd=os.path.join(ENV, 'www'),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
bb = os.path.join(ENV, 'bb'); os.makedirs(bb, exist_ok=True)
busybox = shutil.which('busybox')
if busybox:
    for a in subprocess.check_output([busybox, '--list']).decode().split():
        os.symlink(busybox, os.path.join(bb, a))
os.environ.update(MU_VELLUM_ROOT=os.path.join(ENV, 'vroot'), MU_DATA=os.path.join(ENV, 'data'), MU_RESTART_FLAG=os.path.join(ENV, 'restart'),
                  MU_NO_SYSTEMD='1', MU_ARCH='aarch64', MU_PATH=os.path.join(ENV, 'vroot/bin') + ':' + (bb if busybox else '/usr/bin:/bin'))

# backend binary: ARM build under qemu if possible
bdir = os.path.join(OUT, 'app/backend'); os.makedirs(bdir, exist_ok=True)
shutil.copy(os.path.join(APP, 'backend/agent.sh'), bdir)
qemu = shutil.which('qemu-aarch64-static') or shutil.which('qemu-aarch64')
if qemu and shutil.which('aarch64-linux-gnu-gcc'):
    subprocess.check_call(['aarch64-linux-gnu-gcc', '-O2', '-static', '-o', os.path.join(bdir, 'entry'), os.path.join(APP, 'backend/bridge.c')])
    launch = [qemu, os.path.join(bdir, 'entry')]
else:
    subprocess.check_call(['gcc', '-O2', '-o', os.path.join(bdir, 'entry'), os.path.join(APP, 'backend/bridge.c')])
    launch = [os.path.join(bdir, 'entry')]

from PySide6.QtCore import QObject, Signal, Slot, Property, QUrl, QTimer, QEventLoop, Qt, QPoint
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QmlElement
from PySide6.QtQuick import QQuickView
from PySide6.QtTest import QTest

QML_IMPORT_NAME = "net.asivery.AppLoad"
QML_IMPORT_MAJOR_VERSION = 1
ENDPOINTS = []
class Server:
    """AppLoad's side of the protocol: listen, start the backend, relay packets."""
    def __init__(self):
        self.path = os.path.join(OUT, 'mu.sock'); self.sock = None; self.proc = None
    def start(self, delay=1.2):
        if os.path.exists(self.path): os.unlink(self.path)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET); srv.bind(self.path); srv.listen(1)
        def run():
            time.sleep(delay)                                         # messages before this are dropped, as on the tablet
            self.proc = subprocess.Popen(launch + [self.path], cwd=os.path.join(OUT, 'app'))
            c, _ = srv.accept(); self.sock = c
            while True:
                h = c.recv(8)
                if len(h) < 8: break
                t, n = struct.unpack('<ii', h); d = c.recv(n).decode() if n else ''
                for e in list(ENDPOINTS): e.messageReceived.emit(t, d)
        threading.Thread(target=run, daemon=True).start()
    def send(self, t, s):
        if not self.sock: print('dropped (no backend yet):', s.split('\n')[:2]); return
        b = s.encode(); self.sock.send(struct.pack('<ii', t, len(b)))
        if b: self.sock.send(b)
SERVER = Server()

@QmlElement
class AppLoad(QObject):
    messageReceived = Signal(int, str)
    def __init__(self, parent=None):
        super().__init__(parent); self._id = ''; ENDPOINTS.append(self)
    def getId(self): return self._id
    def setId(self, v): self._id = v
    applicationID = Property(str, getId, setId)
    @Slot(int, str)
    def sendMessage(self, t, s): SERVER.send(t, s)
    @Slot()
    def terminate(self): pass

app = QGuiApplication(sys.argv)
view = QQuickView(); view.setResizeMode(QQuickView.SizeRootObjectToView); view.resize(1620, 2160)
errs = []
view.engine().warnings.connect(lambda ws: [errs.append(w.toString()) or print('QMLWARN', w.toString()) for w in ws])
SERVER.start()
if os.environ.get('MU_RCC'):
    from PySide6.QtCore import QResource
    assert QResource.registerResource(os.environ['MU_RCC'], '/mod-updater')
    view.setSource(QUrl('qrc:/mod-updater/ui/main.qml'))
else:
    view.setSource(QUrl.fromLocalFile(os.path.join(APP, 'ui/main.qml')))
view.show()
root = view.rootObject()
assert root is not None, 'QML failed to load'
def wait(ms):
    loop = QEventLoop(); QTimer.singleShot(ms, loop.quit); loop.exec()
def until(expr, ms=20000):
    t = time.time()
    while time.time() - t < ms / 1000:
        if js(expr): return True
        wait(100)
    print('TIMEOUT waiting for', expr); return False
def shot(name):
    wait(300); p = os.path.join(OUT, name); view.grabWindow().save(p); print('shot', p)
def js(expr):
    from PySide6.QtQml import QQmlExpression, QQmlEngine
    e = QQmlExpression(QQmlEngine.contextForObject(root), root, expr); v = e.evaluate()
    if e.hasError(): print('JSERR', e.error().toString())
    return v[0] if isinstance(v, tuple) else v
def tap(x, y):
    QTest.mouseClick(view, Qt.LeftButton, Qt.NoModifier, QPoint(int(x), int(y))); wait(150)
def find_text(t):
    """centre of the first visible Text item whose text is t"""
    from PySide6.QtQuick import QQuickItem
    stack = [root.parentItem() or root]
    while stack:
        it = stack.pop()
        if it.property('text') == t and it.isVisible() and it.metaObject().className().startswith(('QQuickText', 'Label')):
            p = it.mapToScene(it.boundingRect().center()); return p.x(), p.y()
        stack.extend(it.childItems())
    return None
def tap_text(t):
    p = find_text(t)
    if not p: print('NOT FOUND', t); return False
    tap(*p); return True
try:
    exec(open(sys.argv[1]).read())
finally:
    print('WARNINGS', len(errs))
    if SERVER.proc: SERVER.proc.kill()
    www.kill()

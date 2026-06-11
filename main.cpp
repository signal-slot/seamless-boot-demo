// ASTRA — seamless boot-splash demo (satellite ground-control theme).
//
// Boot chain: Plymouth (script theme, satellite sweeping an orbit)
//   -> this app DEACTIVATES Plymouth (it stays alive holding its last frame,
//      only DRM master is dropped -> eglfs takes over with a page-flip, no black)
//   -> the app reads that frozen frame back from KMS and decodes a
//      near-invisible position marker the theme draws on the bottom edge
//   -> the QML splash continues the satellite sweep from the exact same spot,
//      while the dashboard lazy-loads behind it and cross-fades in.

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QElapsedTimer>
#include <QDebug>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cstddef>
#include <cstring>

#include <fcntl.h>
#include <algorithm>
#if __has_include(<xf86drm.h>) && __has_include(<xf86drmMode.h>)
#  include <xf86drm.h>
#  include <xf86drmMode.h>
#  include <sys/mman.h>
#  define HAVE_LIBDRM 1
#endif

// Send Plymouth a no-argument request and wait for the ACK. Wire format
// (ply-boot-protocol): the command char + NUL; the daemon replies ACK 0x06.
//
// Boot uses two of them:
//   'D' DEACTIVATE  at startup — plymouthd drops DRM master but stays alive
//                   holding its frame, which is what makes the hand-off
//                   black-free (quitting here would free the FB -> black).
//   'Q' QUIT        after OUR first frame is on screen — the CRTC scans our
//                   buffer now, so freeing the daemon's FB cannot blank, and
//                   nothing else stops it (plymouth-quit.service is masked on
//                   this image; a deactivated plymouthd keeps its splash
//                   refresh loop spinning at ~25% CPU forever).
static void plymouthRequest(char cmd)
{
    const int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return;
    struct timeval tv { 3, 0 };
    ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    static const char name[] = "/org/freedesktop/plymouthd"; // abstract socket
    struct sockaddr_un addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    addr.sun_path[0] = '\0';
    std::memcpy(addr.sun_path + 1, name, sizeof(name) - 1);
    const socklen_t len = offsetof(struct sockaddr_un, sun_path) + 1 + (sizeof(name) - 1);

    if (::connect(fd, reinterpret_cast<struct sockaddr *>(&addr), len) == 0) {
        const unsigned char request[] = { (unsigned char)cmd, 0x00 };
        if (::write(fd, request, sizeof(request)) == (ssize_t)sizeof(request)) {
            char ack = 0;
            const ssize_t n = ::read(fd, &ack, 1);
            (void)n;
        }
    }
    ::close(fd);
}

#ifdef HAVE_LIBDRM
// Decode the theme's phase marker from the bottom edge: an 8x3 strip a few LSB
// above the vignette whose x position encodes the sweep head index 0..239
// (x = head * (W-8)/(N-1), see gen.py). The read-back is digital, so the only
// pixels in the row where ALL THREE channels sit >= 5 above the row's darkest
// channel are the marker.
static int decodeMarker(const uchar *base, quint32 w, quint32 h, quint32 pitch)
{
    if (w < 64 || h < 8)
        return -1;
    const uchar *row = base + size_t(pitch) * (h - 2);
    int floorv = 255;
    for (quint32 x = 0; x < w; ++x) {
        const uchar *p = row + size_t(x) * 4;          // XRGB8888: B,G,R,X
        floorv = std::min({ floorv, int(p[0]), int(p[1]), int(p[2]) });
    }
    long sum = 0;
    int cnt = 0;
    for (quint32 x = 0; x < w; ++x) {
        const uchar *p = row + size_t(x) * 4;
        if (p[0] >= floorv + 5 && p[1] >= floorv + 5 && p[2] >= floorv + 5) {
            sum += x;
            ++cnt;
        }
    }
    if (cnt < 3 || cnt > 24)
        return -1;
    const double left = double(sum) / cnt - 3.5;
    const int idx = int(left * 239.0 / double(w - 8) + 0.5);
    return std::clamp(idx, 0, 239);
}
#endif

// Read Plymouth's frozen frame back from whatever framebuffer is still on the
// CRTC and decode the marker. Needs DRM master or CAP_SYS_ADMIN for
// drmModeGetFB (we run as root on the device). Returns the index, or -1.
static int readSatStartIndex()
{
#ifdef HAVE_LIBDRM
    int idx = -1;
    const int fd = ::open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (fd < 0)
        return -1;
    if (drmModeRes *res = drmModeGetResources(fd)) {
        for (int c = 0; c < res->count_crtcs && idx < 0; ++c) {
            drmModeCrtc *crtc = drmModeGetCrtc(fd, res->crtcs[c]);
            if (!crtc)
                continue;
            if (crtc->mode_valid && crtc->buffer_id) {
                if (drmModeFB *fb = drmModeGetFB(fd, crtc->buffer_id)) {
                    if (fb->handle && fb->bpp == 32) {
                        const size_t size = size_t(fb->pitch) * fb->height;
                        void *map = MAP_FAILED;
                        drm_mode_map_dumb mreq = {};
                        mreq.handle = fb->handle;
                        if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq) == 0)
                            map = ::mmap(nullptr, size, PROT_READ, MAP_SHARED, fd, mreq.offset);
                        if (map == MAP_FAILED) {       // not a dumb buffer: try dma-buf
                            int pfd = -1;
                            if (drmPrimeHandleToFD(fd, fb->handle, O_RDONLY, &pfd) == 0 && pfd >= 0) {
                                map = ::mmap(nullptr, size, PROT_READ, MAP_SHARED, pfd, 0);
                                ::close(pfd);
                            }
                        }
                        if (map != MAP_FAILED) {
                            idx = decodeMarker(static_cast<const uchar *>(map),
                                               fb->width, fb->height, fb->pitch);
                            ::munmap(map, size);
                        }
                        drm_gem_close gc = {};
                        gc.handle = fb->handle;
                        drmIoctl(fd, DRM_IOCTL_GEM_CLOSE, &gc);
                    }
                    drmModeFreeFB(fb);
                }
            }
            drmModeFreeCrtc(crtc);
        }
        drmModeFreeResources(res);
    }
    ::close(fd);
    return idx;
#else
    return -1;
#endif
}

int main(int argc, char *argv[])
{
    QElapsedTimer boot;
    boot.start();

    plymouthRequest('D');
    qInfo().nospace() << "[boot] +" << boot.elapsed() << "ms Plymouth deactivated (alive, DRM released)";

    const int satStartIndex = readSatStartIndex();
    qInfo().nospace() << "[boot] +" << boot.elapsed() << "ms sweep phase from KMS: index " << satStartIndex
                      << (satStartIndex < 0 ? " (no marker - sweep restarts)" : "");

    QGuiApplication app(argc, argv);

    QQmlApplicationEngine engine;
    engine.setInitialProperties({ { QStringLiteral("satStartIndex"), satStartIndex } });
    engine.loadFromModule("AstraDemo", "Main");
    if (engine.rootObjects().isEmpty())
        return -1;
    qInfo().nospace() << "[boot] +" << boot.elapsed() << "ms QML loaded";

    // Once our first frame has actually been presented, the hand-off is over —
    // quit the (deactivated, CPU-burning) plymouthd for real.
    if (auto *win = qobject_cast<QQuickWindow *>(engine.rootObjects().first())) {
        QObject::connect(win, &QQuickWindow::frameSwapped, &app, [&boot] {
            plymouthRequest('Q');
            qInfo().nospace() << "[boot] +" << boot.elapsed() << "ms Plymouth quit (first frame is up)";
        }, static_cast<Qt::ConnectionType>(Qt::QueuedConnection | Qt::SingleShotConnection));
    }

    return app.exec();
}

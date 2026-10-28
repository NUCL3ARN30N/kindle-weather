--[[
Screensaver shield.

Maps a fullscreen, override-redirect X11 window without a background while
the weather image is on screen. X never paints into it, so the image drawn
straight to the framebuffer stays intact, and the reader UI underneath
(clock, Wi-Fi and battery indicators) can't repaint over it while the
Kindle sleeps. Killing the process closes the X connection, which removes
the window and lets the UI repaint.

Run with KOReader's LuaJIT and DISPLAY=:0.
--]]

local ffi = require("ffi")

ffi.cdef [[
typedef unsigned long XID;
typedef XID Window;
typedef XID Pixmap;
typedef XID Colormap;
typedef XID Cursor;
typedef int Bool;
typedef struct _XDisplay Display;
typedef struct _Visual Visual;

typedef struct {
    Pixmap background_pixmap;
    unsigned long background_pixel;
    Pixmap border_pixmap;
    unsigned long border_pixel;
    int bit_gravity;
    int win_gravity;
    int backing_store;
    unsigned long backing_planes;
    unsigned long backing_pixel;
    Bool save_under;
    long event_mask;
    long do_not_propagate_mask;
    Bool override_redirect;
    Colormap colormap;
    Cursor cursor;
} XSetWindowAttributes;

Display *XOpenDisplay(const char *name);
int XDefaultScreen(Display *dpy);
Window XRootWindow(Display *dpy, int screen);
int XDisplayWidth(Display *dpy, int screen);
int XDisplayHeight(Display *dpy, int screen);
Window XCreateWindow(Display *dpy, Window parent, int x, int y,
                     unsigned int width, unsigned int height, unsigned int border_width,
                     int depth, unsigned int class, Visual *visual,
                     unsigned long valuemask, XSetWindowAttributes *attributes);
int XStoreName(Display *dpy, Window w, const char *name);
int XMapRaised(Display *dpy, Window w);
int XSync(Display *dpy, Bool discard);

unsigned int sleep(unsigned int seconds);
]]

local CWBackPixmap, CWOverrideRedirect = 1, 512
local InputOutput = 1

local ok, X11 = pcall(ffi.load, "libX11.so.6")
if not ok then
    io.stderr:write("shield: cannot load libX11: ", tostring(X11), "\n")
    os.exit(1)
end

local dpy = X11.XOpenDisplay(nil)
if dpy == nil then
    io.stderr:write("shield: cannot open X display\n")
    os.exit(1)
end

local screen = X11.XDefaultScreen(dpy)
local root = X11.XRootWindow(dpy, screen)
local attrs = ffi.new("XSetWindowAttributes")
attrs.background_pixmap = 0 -- None: X leaves the framebuffer alone
attrs.override_redirect = 1

local win = X11.XCreateWindow(dpy, root, 0, 0,
    X11.XDisplayWidth(dpy, screen), X11.XDisplayHeight(dpy, screen), 0,
    0, InputOutput, nil, -- depth and visual: CopyFromParent
    CWBackPixmap + CWOverrideRedirect, attrs)
X11.XStoreName(dpy, win, "weatherscreen shield")
X11.XMapRaised(dpy, win)
X11.XSync(dpy, 0)
io.stderr:write("shield: up\n")

-- Hold the window until we get killed (SIGTERM from the daemon).
while true do ffi.C.sleep(3600) end

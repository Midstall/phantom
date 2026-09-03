# phantom

Phantom is a cross platform UI framework for Zig, with zero C dependencies.
One application source runs on a GPU, in a browser, and in a terminal.

## Backends

| Backend | Target | What it does |
|---|---|---|
| Prism | Linux, Wayland | Draws through the lattice compositor and the prism GPU renderer. |
| DOM | wasm32 | Compiles to WebAssembly and lays out real HTML elements in a browser. |
| Terminal | Linux, macOS, Windows, the BSDs | Draws inside a terminal emulator. Two render modes, see below. |

Linux gets all three backends. Every other native target gets the terminal
backend only, because the GPU path depends on lattice and prism, and those
build for Linux today.

**Clip and scroll regions nest on every backend.** A `ClipRRect` inside a
`ScrollView`, a `ScrollView` inside another `ScrollView`, and a `GridView`
inside either (`GridView` opens a scroll region of its own) all paint into
the right region, at the right depth. On the DOM backend, each level of
nesting is a real stack: a pop restores the exact parent element and
coordinate origin its matching push saved. The stack holds up to 32 open
regions; a display list that nests deeper than that skips the extra region
and reports a fault rather than mispositioning the rest of the frame.

**macOS and Windows are cross compiled, not tested.** The terminal backend
follows the same specification as the Linux terminal path, but nobody has run
it on a real Mac or a real Windows machine. Treat those two targets as
unverified until someone does.

The cross compile itself only covers the SHIPPING path, not the test suite.
`examples/app` builds clean for `-Dtarget=x86_64-windows` and
`-Dtarget=aarch64-macos`. `zig build test -Dtarget=x86_64-windows` does not
compile: `lib/phantom.zig`'s root test block references `backend.prism`
unconditionally, and prism's drivers are Linux only, so the test binary never
gets far enough to reach the terminal code being tested. If you need to type
check the terminal path itself for Windows, build `examples/app`, not the
test suite.

**Windows is experimental and incomplete**, not merely untested. The
terminal backend runs there, but several pieces of the console model that
posix gets almost for free are simply not built yet:

- **No mouse input.** Raw mode turns on virtual terminal input, which is
  documented to deliver keyboard escape sequences the same way a posix
  terminal does, but it does not turn on `ENABLE_MOUSE_INPUT`. No mouse
  event of any kind reaches the application.
- **No resize detection.** Posix gets a resize two ways: a SIGWINCH handler
  or an in-band report from the terminal. Windows has neither wired up, so
  the display is sized once at startup and never again. Resizing the window
  after that desyncs the display from the real console size for the rest of
  the run.
- **No idle redraw.** Nothing drives a frame while the user is not typing,
  so anything meant to animate on its own sits frozen between keystrokes.
- **No input timeout**, so a read blocks until a key arrives rather than
  returning on a frame deadline the way the posix path does.
- **No code page handling.** Non-ASCII output can corrupt rows on a console
  left at its default code page.

None of these are small bugs; each is a missing piece of the Windows
console model and real work to add. This is a known state, not an oversight,
and the project owner decides when Windows gets them.

## The web backend and Content Security Policy

A Phantom page needs a Content Security Policy that permits three things. None of
them are optional today, and a policy that omits them gives a blank page with a
console violation rather than an error anyone can act on, so they are written
here rather than discovered.

| Directive | Needs | Why |
|---|---|---|
| `script-src` | `'self'` and `'wasm-unsafe-eval'` | The page is a shell that loads `boot.js` as a file, so `'self'` is enough and no nonce or `'unsafe-inline'` is wanted. `'wasm-unsafe-eval'` is what allows the module to be compiled at all. |
| `style-src` | `'unsafe-inline'` | Every node is positioned with a `style` attribute. A browser reports these against `style-src-attr` and suggests `'unsafe-hashes'`, so that is what the console will name; `style-src 'unsafe-inline'` covers it. A style ATTRIBUTE cannot carry a nonce, so there is no strict form of this today. |
| `font-src`, `img-src` | `data:` | A font is embedded as `@font-face { src: url(data:font/otf;base64,...) }` and an `Image` emits a `data:image/png` URL. |

`connect-src 'self'` is enough for an application talking to its own server,
because a request for the page's own host is handed to the browser as a bare
path. See `lib/phantom/web_net.zig` for the one rule that makes that true.

The `style-src` line is the one worth arguing about, and it is a real cost rather
than an oversight: it is the direct consequence of the DOM backend positioning
every node itself instead of emitting a stylesheet.

## Choosing a backend

`phantom.App.run` picks a backend at startup:

1. If the `PHANTOM_BACKEND` environment variable is `tui` or `gpu`, that
   choice wins outright.
2. Otherwise, on Linux: a `WAYLAND_DISPLAY` or `DISPLAY` environment variable
   selects the GPU backend, and a terminal on stdout selects the terminal
   backend.
3. On every other target, a terminal on stdout selects the terminal backend.
4. With no display and no terminal, `App.run` prints an error and returns
   `error.NoBackend` rather than drawing nothing.

An unrecognised `PHANTOM_BACKEND` value is treated as absent, and detection
runs as normal.

## The terminal backend

The terminal backend has two render modes.

- **Pixel mode.** The frame renders through the same prism GPU path the
  window backend uses, into an offscreen image, and reaches the terminal
  with the kitty graphics protocol. The result matches the window path:
  real fonts, real anti-aliasing, true rounded corners. Ghostty and kitty
  support this. Pixel mode needs the Linux GPU path, so it is only ever
  chosen on Linux.
- **Cell mode.** The frame becomes character cells with truecolor.
  Borders become box drawing glyphs, and the terminal itself draws the
  text, using whatever font the user has configured. Cell mode runs in any
  terminal, including inside tmux or screen, and over ssh. It is the only
  mode available on macOS, Windows, and the BSDs.

`phantom.Tui.run` chooses the mode with a capability probe: it asks the
terminal what it supports and picks pixel mode only when the terminal
answers that it has kitty graphics. A terminal multiplexer such as tmux
does not forward the graphics protocol reliably, so running inside one
always falls back to cell mode, even inside a terminal that supports pixel
mode on its own.

Set `PHANTOM_TUI=pixel` or `PHANTOM_TUI=cells` to force a mode instead of
probing. An unrecognised value is treated as absent and the probe runs as
normal. Forcing `pixel` on a target with no GPU path still falls back to
cell mode, because there is no pixel path to run.

### Embedding it

`phantom.Tui.run` owns the process: it takes the signals, the screen and the
loop. A program that already has its own loop, its own signal handling or its
own logging drives `phantom.tui.Session` instead. `Tui.run` is `init`, `step`
until it returns false, then `deinit`, and nothing more.

```zig
var session: phantom.tui.Session = undefined;
try session.init(gpa, io, environ, phantom.Root.of(App, App.build, &app), .{
    .install_signal_handlers = false, // the caller keeps its own
    .stderr = .leave,                 // the caller already logs somewhere safe
    .interrupt = .notify,             // ctrl-c is reported, not obeyed
    .writer = &my_writer,             // frames go through the caller's writer
});
defer session.deinit();

while (try session.step()) {
    if (session.takeInterrupt()) try app.stopWhenSafe();
}
```

A `Session` holds pointers into its own fields, so build it in place at an
address that does not move.

Every `Options` field is one decision the caller can take back. `raw_mode`,
`query_capabilities` and `own_screen` each cover one thing the session would
otherwise do to the terminal; `in`, `out`, `writer` and `size` say where it
reads, writes and how large it is; `install_signal_handlers`,
`install_panic_hook` and `stderr` say how much of the process it may take over.
Setting them all gives a session with no terminal in it at all, which is how
the terminal path is tested.

Ctrl-c deserves its own note. Raw mode turns `ISIG` off, so ctrl-c is **not** a
signal: the terminal delivers it as an ordinary key and no `SIGINT` handler ever
runs for it. `Interrupt.notify` is therefore the only way a caller gets to stop
at a point of its own choosing.

#### Who reads the input

`input` decides whether the session reads the stream itself or waits to be fed.
It follows `raw_mode` unless set, and that default is a safety rule rather than
a convenience: raw mode sets VMIN 0 and VTIME 1, which is what makes a read
return promptly with nothing to report. Without raw mode the stream's blocking
behaviour belongs to whoever opened it, and reading a pipe with nothing on it
and no end of stream stops the loop dead. So a session that did not set raw mode
waits for `session.feed(bytes)` instead. Feed from your own reader; the bytes are
decoded on the next `step`.

`input = .own` overrides it, for a caller that put the terminal in raw mode
itself. Do not point two readers at one descriptor: they race for every byte and
the loser sees a torn escape sequence.

#### Drawing a region instead of the display

`own_screen = false` leaves the alternate screen and the terminal's scrollback
alone and draws in place. `position` then says where the frame lands.

- `.{ .absolute = .{ .row = r, .col = c } }` pins the region to a fixed place on
  the screen.
- `.relative` draws wherever the cursor already is and puts it back afterwards.
  This is what a band **under scrolling text** needs: such a band has no fixed
  screen row, because every line printed above scrolls it up by one, so an
  absolute address would pin it to a row the text then scrolls through.

`.relative` leaves two things to the caller, and neither can be done from inside
the session:

1. **Make room first.** Relative cursor moves do not scroll, so moving down at
   the last row of the screen goes nowhere and the whole band lands on one line.
   Print as many newlines as the band has rows, then move back up, before the
   first frame.
2. **Call `session.invalidate()` after printing.** The front buffer records what
   each *cell* holds, not where the band is. Printing a line scrolls the band to
   a new place with its old contents still on screen, and a diff against an
   unchanged front buffer would write nothing at all and leave the stale copy
   where the scroll put it.

`phantom.Root` carries a userdata pointer beside the build function, so a tree
can draw from the caller's own state rather than from a process global. That is
also what lets two sessions run in one process.

### Known limits

- **Column widths follow the East Asian Width property of one codepoint at
  a time.** This is not grapheme cluster segmentation, so a sequence
  joined with a zero width joiner, such as a family emoji, reports the sum
  of its parts' widths and not the one column pair the terminal actually
  draws it in.
- **Pixel mode has no font fallback.** It rasterises with the fonts
  Phantom bundles, and a character outside those fonts draws nothing.
  Cell mode has no such gap: the terminal draws the glyph with its own
  configured font and font fallback chain.

## Environment variables

| Variable | Values | Effect |
|---|---|---|
| `PHANTOM_BACKEND` | `tui`, `gpu` | Forces the backend `App.run` picks. Any other value is ignored. |
| `PHANTOM_TUI` | `pixel` (or `pixels`), `cells` (or `cell`) | Forces the terminal render mode instead of probing. Any other value is ignored. |
| `PHANTOM_TUI_KEEP_COREDUMP` | any value | Skips installing the terminal's SIGABRT handler, so a crash produces a real core dump instead of a clean terminal restore. Set it when debugging a crash. Leave it unset for a shipped application. |

## Building and running

```sh
zig build test          # the full test suite
zig build run-hello     # the window backend (needs a Wayland compositor)
zig build run-hello:web # builds the wasm + HTML demo
zig build run-hello:tui # the terminal backend (needs a real terminal)
```

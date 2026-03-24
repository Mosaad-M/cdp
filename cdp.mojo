# ============================================================================
# cdp.mojo — Chrome DevTools Protocol Client
# ============================================================================
#
# Provides Browser and Page abstractions over the Chrome DevTools Protocol.
# CDP communicates via JSON messages over WebSocket.
#
# Flow:
#   1. Launch Chrome via fork()+execv() on a known binary path
#   2. GET http://localhost:PORT/json/version via TcpSocket
#   3. Connect WebSocket to page's webSocketDebuggerUrl
#   4. Send CDP commands as JSON, receive responses
#
# Usage:
#   var browser = Browser.launch()
#   var page = browser.new_page()
#   page.navigate("https://example.com")
#   page.wait_for_load()
#   var title = page.evaluate("document.title")
#   var html = page.content()
#   page.close()
#   browser.close()
#
# ============================================================================

from websocket import WebSocket, WebSocketFrame
from json import JsonValue, parse_json
from tcp import TcpSocket
from ffi import external_call
from memory.unsafe_pointer import alloc


# ============================================================================
# Constants
# ============================================================================

alias DEFAULT_CDP_PORT = 9222
alias DEFAULT_TIMEOUT_MS = 30000


# ============================================================================
# POSIX helpers via C FFI
# ============================================================================


fn _system(cmd: String) -> Int32:
    """Run a shell command via system() with explicit null-terminated buffer."""
    var cb = cmd.as_bytes()
    var n = len(cb)
    var buf = alloc[UInt8](n + 1)
    for i in range(n):
        (buf + i)[] = cb[i]
    (buf + n)[] = 0
    var ret = external_call["system", Int32](buf)
    buf.free()
    return ret


fn _nanosleep(secs: Int):
    """Sleep for secs seconds via nanosleep()."""
    # struct timespec { int64 tv_sec; int64 tv_nsec; } = 16 bytes
    var ts = alloc[UInt8](16)
    var s = Int64(secs)
    for i in range(8):
        (ts + i)[] = UInt8(Int(s >> Int64(i * 8)) & 0xFF)
    for i in range(8, 16):
        (ts + i)[] = 0
    _ = external_call["nanosleep", Int32](ts, Int(0))
    ts.free()


fn _getenv(name: String) -> String:
    """Read an environment variable. Returns empty string if not set."""
    var cb = name.as_bytes()
    var n = len(cb)
    var buf = alloc[Int8](n + 1)
    for i in range(n):
        (buf + i)[] = Int8(cb[i])
    (buf + n)[] = Int8(0)
    var ptr = external_call["getenv", Int](buf)
    buf.free()
    if ptr == 0:
        return String("")
    var slen = external_call["strlen", Int](ptr)
    var out = alloc[UInt8](slen)
    _ = external_call["memcpy", Int](Int(out), ptr, slen)
    var bytes = List[UInt8](capacity=slen)
    for i in range(slen):
        bytes.append((out + i)[])
    out.free()
    return String(unsafe_from_utf8=bytes^)


fn _sleep_ms(ms: Int):
    """Sleep for ms milliseconds via nanosleep()."""
    # struct timespec { int64 tv_sec; int64 tv_nsec; }
    var ts = alloc[UInt8](16)
    var secs = Int64(ms // 1000)
    var nsecs = Int64((ms % 1000) * 1_000_000)
    for i in range(8):
        (ts + i)[] = UInt8(Int(secs >> Int64(i * 8)) & 0xFF)
    for i in range(8):
        (ts + 8 + i)[] = UInt8(Int(nsecs >> Int64(i * 8)) & 0xFF)
    _ = external_call["nanosleep", Int32](ts, Int(0))
    ts.free()


fn _clock_ms() -> Int:
    """Return monotonic clock time in milliseconds via clock_gettime()."""
    # struct timespec { int64 tv_sec; int64 tv_nsec; } at 16 bytes
    var ts = alloc[UInt8](16)
    for i in range(16):
        (ts + i)[] = 0
    _ = external_call["clock_gettime", Int32](Int32(1), ts)  # CLOCK_MONOTONIC=1
    var secs: Int64 = 0
    var nsecs: Int64 = 0
    for i in range(8):
        secs |= Int64(Int((ts + i)[]) << (i * 8))
        nsecs |= Int64(Int((ts + 8 + i)[]) << (i * 8))
    ts.free()
    return Int(secs) * 1000 + Int(nsecs) // 1_000_000


fn _escape_js(s: String) -> String:
    """Escape a string for safe embedding inside a JS single-quoted string literal."""
    var result = String("")
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        var c = bytes[i]
        if c == UInt8(ord("'")):
            result += "\\'"
        elif c == UInt8(ord("\\")):
            result += "\\\\"
        elif c == UInt8(ord("\n")):
            result += "\\n"
        elif c == UInt8(ord("\r")):
            result += "\\r"
        else:
            var b = List[UInt8]()
            b.append(c)
            result += String(unsafe_from_utf8=b^)
    return result


fn _access(path: String) -> Bool:
    """Check if file exists via access(path, F_OK)."""
    var cb = path.as_bytes()
    var n = len(cb)
    var buf = alloc[UInt8](n + 1)
    for i in range(n):
        (buf + i)[] = cb[i]
    (buf + n)[] = 0
    var ret = external_call["access", Int32](buf, Int32(0))  # F_OK=0
    buf.free()
    return ret == 0


fn chrome_available() -> Bool:
    """Check if Chrome/Chromium is installed and usable.

    Returns False in CI environments (GITHUB_ACTIONS=true) since
    headless Chrome is unreliable in container sandboxes.
    """
    # Skip in CI: Chrome often crashes in container environments
    if _getenv("GITHUB_ACTIONS") == "true":
        return False
    var paths = List[String]()
    paths.append("/usr/bin/google-chrome")
    paths.append("/usr/local/bin/google-chrome")
    paths.append("/usr/bin/chromium-browser")
    paths.append("/usr/local/bin/chromium-browser")
    paths.append("/usr/bin/chromium")
    paths.append("/snap/bin/chromium")
    for i in range(len(paths)):
        if _access(paths[i]):
            return True
    return False


fn _find_chrome() raises -> String:
    """Return full path to Chrome/Chromium binary."""
    var paths = List[String]()
    paths.append("/usr/bin/google-chrome")
    paths.append("/usr/local/bin/google-chrome")
    paths.append("/usr/bin/chromium-browser")
    paths.append("/usr/local/bin/chromium-browser")
    paths.append("/usr/bin/chromium")
    paths.append("/snap/bin/chromium")
    for i in range(len(paths)):
        if _access(paths[i]):
            return paths[i]
    raise Error("cdp: Chrome/Chromium not found in known paths")


fn _kill_process(pid: Int32):
    """Send SIGTERM to a process."""
    if pid > 0:
        _ = external_call["kill", Int32](pid, Int32(15))  # SIGTERM=15


fn _spawn_chrome(chrome_path: String, port: Int, headless: Bool) raises -> Int32:
    """Launch Chrome via fork()+execv(). Returns Chrome's PID."""
    var args = List[String]()
    args.append(chrome_path)
    if headless:
        args.append("--headless=new")
    args.append("--remote-debugging-port=" + String(port))
    args.append("--no-first-run")
    args.append("--no-default-browser-check")
    args.append("--no-sandbox")
    args.append("--disable-dev-shm-usage")
    args.append("--disable-gpu")
    args.append("--disable-extensions")
    args.append("--log-level=3")
    args.append("--disable-logging")
    args.append("--user-data-dir=/tmp/chrome-cdp-" + String(port))
    args.append("about:blank")

    var n = len(args)

    # Allocate a single pool buffer for all argument strings
    var total = 0
    for i in range(n):
        total += len(args[i].as_bytes()) + 1
    var pool = alloc[UInt8](total)
    var offset = 0

    # Build char** argv array: (n+1) 8-byte pointer slots
    var argv = alloc[UInt8]((n + 1) * 8)

    for i in range(n):
        var b = args[i].as_bytes()
        var bn = len(b)
        for j in range(bn):
            (pool + offset + j)[] = b[j]
        (pool + offset + bn)[] = 0
        var addr = Int(pool) + offset
        offset += bn + 1
        for k in range(8):
            (argv + i * 8 + k)[] = UInt8((addr >> (k * 8)) & 0xFF)

    # NULL-terminate argv
    for k in range(8):
        (argv + n * 8 + k)[] = 0

    var pid = external_call["fork", Int32]()

    if pid == 0:
        # Child: detach, silence output, exec Chrome
        _ = external_call["setsid", Int32]()
        var dn_b = String("/dev/null").as_bytes()
        var dn_n = len(dn_b)
        var dn_buf = alloc[UInt8](dn_n + 1)
        for i in range(dn_n):
            (dn_buf + i)[] = dn_b[i]
        (dn_buf + dn_n)[] = 0
        var null_fd = external_call["open", Int32](dn_buf, Int32(2))  # O_RDWR=2
        if null_fd >= 0:
            _ = external_call["dup2", Int32](null_fd, Int32(0))
            _ = external_call["dup2", Int32](null_fd, Int32(1))
            _ = external_call["dup2", Int32](null_fd, Int32(2))
            if null_fd > 2:
                _ = external_call["close", Int32](null_fd)
        # pool starts with chrome_path (first arg)
        _ = external_call["execv", Int32](Int(pool), Int(argv))
        _ = external_call["_exit", Int32](Int32(1))

    # Parent: free buffers
    pool.free()
    argv.free()

    if pid < 0:
        raise Error("cdp: fork() failed to launch Chrome")
    return pid


fn _tcp_get(host: String, port: Int, path: String) raises -> String:
    """HTTP/1.0 GET via TcpSocket. Server closes connection after response."""
    var sock = TcpSocket()
    sock.connect(host, port)
    _ = sock.send(
        "GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\nConnection: close\r\n\r\n"
    )
    var raw = sock.recv_all()
    sock.close()

    # Find \r\n\r\n (headers/body boundary)
    for i in range(len(raw) - 3):
        if (
            raw[i] == 13
            and raw[i + 1] == 10
            and raw[i + 2] == 13
            and raw[i + 3] == 10
        ):
            var body = List[UInt8]()
            for j in range(i + 4, len(raw)):
                body.append(raw[j])
            if len(body) == 0:
                raise Error("cdp: empty HTTP response body")
            return String(unsafe_from_utf8=body^)
    raise Error("cdp: malformed HTTP response")


# ============================================================================
# Browser — Manages Chrome Process
# ============================================================================


struct Browser(Movable):
    """Manages a headless Chrome process with CDP enabled."""

    var port: Int
    var _chrome_pid: Int
    var _launched: Bool

    fn __init__(out self):
        self.port = DEFAULT_CDP_PORT
        self._chrome_pid = 0
        self._launched = False

    fn __moveinit__(out self, deinit take: Self):
        self.port = take.port
        self._chrome_pid = take._chrome_pid
        self._launched = take._launched

    @staticmethod
    fn launch(port: Int = DEFAULT_CDP_PORT, headless: Bool = True) raises -> Browser:
        """Launch Chrome with remote debugging enabled.

        Args:
            port: CDP port (default 9222).
            headless: Run headless (default True).

        Returns:
            Browser instance connected to Chrome.

        Raises:
            Error if Chrome cannot be started.
        """
        var chrome_path = _find_chrome()
        var browser = Browser()
        browser.port = port
        browser._chrome_pid = Int(_spawn_chrome(chrome_path, port, headless))
        browser._launched = True

        _nanosleep(3)  # Wait for Chrome to start

        # Verify Chrome is responding
        try:
            var body = _tcp_get("localhost", port, "/json/version")
            var version = parse_json(body)
            if not version.has_key("Browser"):
                raise Error("cdp: Chrome not responding on port " + String(port))
        except e:
            raise Error("cdp: failed to connect to Chrome: " + String(e))

        return browser^

    fn get_targets(self) raises -> JsonValue:
        """Get list of page targets from Chrome.

        Returns:
            JsonValue array of target objects.
        """
        var body = _tcp_get("localhost", self.port, "/json")
        return parse_json(body)

    fn new_page(mut self) raises -> Page:
        """Open a new browser tab using CDP Target.createTarget.

        The /json/new HTTP endpoint is deprecated in Chrome 113+.
        This method connects to the browser-level WebSocket (from
        /json/version) and sends Target.createTarget to create a new tab.

        Returns:
            Page connected to the new tab.

        Raises:
            Error if tab creation or connection fails.
        """
        # Get browser-level WebSocket URL
        var version_body = _tcp_get("localhost", self.port, "/json/version")
        var version = parse_json(version_body)
        if not version.has_key("webSocketDebuggerUrl"):
            raise Error("cdp: no browser webSocketDebuggerUrl in /json/version")
        var browser_ws_url = version.get_string("webSocketDebuggerUrl")
        if len(browser_ws_url) == 0:
            raise Error("cdp: browser webSocketDebuggerUrl is empty")

        # Send Target.createTarget via browser-level WebSocket
        var browser_ws = WebSocket()
        browser_ws.connect(browser_ws_url)
        browser_ws.send_text(
            '{"id":1,"method":"Target.createTarget","params":{"url":"about:blank"}}'
        )

        # Read messages until we find the response for id=1
        var target_id = String("")
        while True:
            var frame = browser_ws.recv()
            var text = frame.as_text()
            if len(text) == 0:
                continue
            try:
                var resp = parse_json(text)
                if resp.has_key("id"):
                    var resp_id = resp.get("id")
                    if resp_id.kind == 2 and resp_id.as_int() == 1:
                        if resp.has_key("result"):
                            var result = resp.get("result")
                            if result.has_key("targetId"):
                                target_id = result.get_string("targetId")
                        break
            except:
                continue

        browser_ws.close()

        if len(target_id) == 0:
            raise Error("cdp: Target.createTarget returned no targetId")

        var page_ws_url = (
            "ws://localhost:"
            + String(self.port)
            + "/devtools/page/"
            + target_id
        )
        return Page.connect_to_target(page_ws_url)

    fn close(mut self):
        """Kill the Chrome process and clean up."""
        if self._launched:
            _kill_process(Int32(self._chrome_pid))
            _ = _system("rm -rf /tmp/chrome-cdp-" + String(self.port))
            self._launched = False


# ============================================================================
# Page — CDP Session for a Single Page
# ============================================================================


struct Page(Movable):
    """A CDP session connected to a browser page via WebSocket."""

    var _ws: WebSocket
    var _msg_id: Int
    var _connected: Bool

    fn __init__(out self):
        self._ws = WebSocket()
        self._msg_id = 0
        self._connected = False

    fn __moveinit__(out self, deinit take: Self):
        self._ws = take._ws^
        self._msg_id = take._msg_id
        self._connected = take._connected

    @staticmethod
    fn connect_to_target(ws_url: String) raises -> Page:
        """Connect to a CDP target via its WebSocket URL.

        Args:
            ws_url: WebSocket debugger URL from /json endpoint.

        Returns:
            Connected Page instance.
        """
        var page = Page()
        page._ws.connect(ws_url)
        page._connected = True

        # Enable Page domain for navigation events
        _ = page._send_command("Page.enable", "{}")

        return page^

    fn _next_id(mut self) -> Int:
        """Get next message ID."""
        self._msg_id += 1
        return self._msg_id

    fn _send_command(
        mut self, method: String, params: String
    ) raises -> JsonValue:
        """Send a CDP command and wait for response.

        Args:
            method: CDP method name (e.g. "Page.navigate").
            params: JSON params string (e.g. '{"url":"..."}').

        Returns:
            Response JSON.
        """
        if not self._connected:
            raise Error("cdp: page not connected")

        var msg_id = self._next_id()
        var msg = (
            '{"id":'
            + String(msg_id)
            + ',"method":"'
            + method
            + '","params":'
            + params
            + "}"
        )

        self._ws.send_text(msg)

        # Read responses until we get one matching our ID
        while True:
            var frame = self._ws.recv()
            var resp_text = frame.as_text()

            if len(resp_text) == 0:
                continue

            var resp = parse_json(resp_text)

            # Check if this is our response (has matching id)
            if resp.has_key("id"):
                var resp_id = resp.get("id")
                if resp_id.kind == 2:  # JSON_NUMBER
                    if resp_id.as_int() == msg_id:
                        # Check for error
                        if resp.has_key("error"):
                            var err = resp.get("error")
                            var err_msg = String("CDP error")
                            if err.has_key("message"):
                                err_msg = err.get_string("message")
                            raise Error("cdp: " + method + ": " + err_msg)
                        return resp^

            # Otherwise it's an event — ignore and keep reading

        # Unreachable
        return parse_json("{}")

    fn navigate(mut self, url: String) raises:
        """Navigate to a URL."""
        _ = self._send_command("Page.navigate", '{"url":"' + url + '"}')

    fn wait_for_load(mut self) raises:
        """Wait for the page to finish loading (Page.loadEventFired)."""
        while True:
            var frame = self._ws.recv()
            var text = frame.as_text()
            if len(text) == 0:
                continue

            var event = parse_json(text)
            if event.has_key("method"):
                var method_name = event.get_string("method")
                if method_name == "Page.loadEventFired":
                    return

    fn evaluate(mut self, expression: String) raises -> String:
        """Evaluate JavaScript in the page.

        Args:
            expression: JavaScript expression to evaluate.

        Returns:
            String result of the expression.
        """
        # Escape quotes in expression
        var escaped = String("")
        var expr_bytes = expression.as_bytes()
        for i in range(len(expr_bytes)):
            var c = expr_bytes[i]
            if c == ord('"'):
                escaped += '\\"'
            elif c == ord("\\"):
                escaped += "\\\\"
            elif c == ord("\n"):
                escaped += "\\n"
            else:
                var byte_list = List[UInt8]()
                byte_list.append(c)
                escaped += String(unsafe_from_utf8=byte_list^)

        var resp = self._send_command(
            "Runtime.evaluate",
            '{"expression":"' + escaped + '","returnByValue":true}',
        )

        # Extract result value
        if resp.has_key("result"):
            var result = resp.get("result")
            if result.has_key("result"):
                var inner = result.get("result")
                if inner.has_key("value"):
                    var val = inner.get("value")
                    if val.kind == 3:  # JSON_STRING
                        return val.as_string()
                    elif val.kind == 2:  # JSON_NUMBER
                        return String(val.as_int())
                    elif val.kind == 1:  # JSON_BOOL
                        if val.as_bool():
                            return String("true")
                        return String("false")
                    elif val.kind == 0:  # JSON_NULL
                        return String("null")

        return String("")

    fn content(mut self) raises -> String:
        """Get the full page HTML."""
        return self.evaluate("document.documentElement.outerHTML")

    fn query_selector_text(mut self, selector: String) raises -> String:
        """Get text content of first matching element."""
        return self.evaluate(
            "(() => { var el = document.querySelector('"
            + selector
            + "'); return el ? el.textContent : ''; })()"
        )

    fn query_selector_all_text(mut self, selector: String) raises -> String:
        """Get JSON array of text content from all matching elements."""
        return self.evaluate(
            "JSON.stringify([...document.querySelectorAll('"
            + selector
            + "')].map(el => el.textContent))"
        )

    fn click(mut self, selector: String) raises:
        """Click the first element matching selector.

        Args:
            selector: CSS selector string.
        """
        _ = self.evaluate(
            "document.querySelector('" + _escape_js(selector) + "').click()"
        )

    fn type_text(mut self, selector: String, text: String) raises:
        """Set input value and dispatch input/change events.

        Args:
            selector: CSS selector for the input element.
            text: Text to type into the element.
        """
        var js = (
            "var el=document.querySelector('"
            + _escape_js(selector)
            + "');"
            + "el.value='"
            + _escape_js(text)
            + "';"
            + "el.dispatchEvent(new Event('input',{bubbles:true}));"
            + "el.dispatchEvent(new Event('change',{bubbles:true}))"
        )
        _ = self.evaluate(js)

    fn scroll_to(mut self, selector: String) raises:
        """Scroll the first matching element into view.

        Args:
            selector: CSS selector string.
        """
        _ = self.evaluate(
            "document.querySelector('"
            + _escape_js(selector)
            + "').scrollIntoView(true)"
        )

    fn scroll_by(mut self, x: Int, y: Int) raises:
        """Scroll the window by (x, y) pixels.

        Args:
            x: Horizontal scroll amount in pixels.
            y: Vertical scroll amount in pixels.
        """
        _ = self.evaluate(
            "window.scrollBy(" + String(x) + "," + String(y) + ")"
        )

    fn wait_for_selector(
        mut self, selector: String, timeout_ms: Int = 10000
    ) raises:
        """Poll until selector matches an element, or timeout.

        Args:
            selector: CSS selector string.
            timeout_ms: Maximum wait time in milliseconds (default 10000).

        Raises:
            Error if selector is not found within timeout_ms.
        """
        var deadline = _clock_ms() + timeout_ms
        while True:
            var found = self.evaluate(
                "document.querySelector('"
                + _escape_js(selector)
                + "') ? 'true' : 'false'"
            )
            if found == "true":
                return
            if _clock_ms() >= deadline:
                raise Error(
                    "wait_for_selector: '"
                    + selector
                    + "' not found after "
                    + String(timeout_ms)
                    + "ms"
                )
            _sleep_ms(100)

    fn close(mut self) raises:
        """Close the CDP connection."""
        if self._connected:
            self._ws.close()
            self._connected = False

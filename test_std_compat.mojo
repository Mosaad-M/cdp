# test_std_compat.mojo — cdp must not break programs that use Mojo's std
#
# A Mojo program may declare each C function with one signature only. std
# declares getenv, clock_gettime, nanosleep, open/read/write/close and errno
# access itself. cdp 1.1 declared getenv, clock_gettime, nanosleep, access and
# open/close with other types, so any program combining Browser/Page with
# std.os.getenv, open(), the time functions or (with tls >= 1.7.0, which uses
# std file I/O) any HTTPS client failed to compile ("existing function with
# conflicting signature").
#
# Compiling this file is the test: it reaches Browser.launch (Chrome spawn,
# deadline loops) and Page's command/evaluate paths together with those std
# APIs. Running it exercises the std calls only.

from std.ffi import get_errno
from std.os import getenv, listdir
from std.os.path import exists
from std.sys import argv
from std.time import monotonic, perf_counter_ns, sleep
from cdp import Browser

comptime PATH = "/tmp/mojo_cdp_std_compat.txt"


def browser_paths() raises:
    """Never run: compiled so that cdp's C declarations are present."""
    var browser = Browser.launch()
    var page = browser.new_page()
    page.navigate("https://example.com/")
    page.wait_for_load()
    _ = page.evaluate("1 + 1")
    page.wait_for_selector("body")
    _ = browser.get_targets()
    page.close()
    browser.close()


def main() raises:
    print("test_std_compat")
    if len(argv()) > 1000:
        browser_paths()
    with open(PATH, "w") as f:
        f.write("std open() next to cdp\n")
    with open(PATH, "r") as f:
        if not f.read().startswith("std open()"):
            raise Error("std open()/read() round trip failed")
    _ = listdir("/tmp")
    _ = getenv("HOME")
    _ = exists(PATH)
    _ = get_errno()
    sleep(0.001)
    _ = perf_counter_ns() + monotonic()
    print("  PASS: Browser/Page compile next to std open/listdir/getenv/get_errno/clocks/sleep")
    print("Results: 1 passed, 0 failed")

# ============================================================================
# test_cdp.mojo — CDP Module Tests
# ============================================================================
#
# Tests require Chrome/Chromium installed. Tests that need a browser are
# skipped if Chrome is unavailable.
# ============================================================================

from cdp import Browser, Page, chrome_available
from json import parse_json


# ============================================================================
# Test helpers
# ============================================================================


fn assert_true(cond: Bool, label: String) raises:
    if not cond:
        raise Error(label + ": expected True, got False")


fn assert_eq(actual: String, expected: String, label: String) raises:
    if actual != expected:
        raise Error(label + ": expected '" + expected + "', got '" + actual + "'")


# ============================================================================
# Unit tests (no browser needed)
# ============================================================================


fn test_browser_init() raises:
    """Browser initializes with default values."""
    var b = Browser()
    assert_true(b.port == 9222, "default port")
    assert_true(not b._launched, "not launched")


fn test_page_init() raises:
    """Page initializes with default values."""
    var p = Page()
    assert_true(not p._connected, "not connected")
    assert_true(p._msg_id == 0, "msg_id starts at 0")


# ============================================================================
# Integration tests (require Chrome)
# ============================================================================


fn test_browser_launch_and_targets() raises:
    """Launch Chrome, get targets, close."""
    var browser = Browser.launch()

    var targets = browser.get_targets()
    assert_true(targets.kind == 4, "targets is array")  # JSON_ARRAY

    browser.close()


fn test_navigate_and_evaluate() raises:
    """Navigate to a page and evaluate JavaScript."""
    var browser = Browser.launch()
    var targets = browser.get_targets()

    # Get first page target's WebSocket URL
    var ws_url = String("")
    if targets.kind == 4:  # JSON_ARRAY
        for i in range(len(targets)):
            var target = targets.get(i)
            if target.has_key("type"):
                var target_type = target.get_string("type")
                if target_type == "page":
                    ws_url = target.get_string("webSocketDebuggerUrl")
                    break

    if len(ws_url) == 0:
        browser.close()
        raise Error("no page target found")

    var page = Page.connect_to_target(ws_url)

    # Navigate to a data URI (no network needed)
    page.navigate(
        "data:text/html,<html><head><title>Test</title></head>"
        "<body><h1>Hello CDP</h1></body></html>"
    )
    page.wait_for_load()

    # Evaluate JavaScript
    var title = page.evaluate("document.title")
    assert_eq(title, "Test", "page title")

    var h1 = page.query_selector_text("h1")
    assert_eq(h1, "Hello CDP", "h1 text")

    page.close()
    browser.close()


# ============================================================================
# Main
# ============================================================================


fn main() raises:
    var passed = 0
    var failed = 0

    fn run_test(
        name: String,
        mut passed: Int,
        mut failed: Int,
        test_fn: fn () raises -> None,
    ):
        try:
            test_fn()
            print("  PASS:", name)
            passed += 1
        except e:
            print("  FAIL:", name, "-", String(e))
            failed += 1

    print("=== CDP Module Tests ===")
    print()

    # Unit tests (no browser)
    print("-- Unit Tests --")
    run_test("browser init", passed, failed, test_browser_init)
    run_test("page init", passed, failed, test_page_init)

    # Integration tests (require Chrome)
    var has_chrome = chrome_available()
    if has_chrome:
        print("-- Integration (Chrome) --")
        run_test("browser launch + targets", passed, failed, test_browser_launch_and_targets)
        run_test("navigate + evaluate", passed, failed, test_navigate_and_evaluate)
    else:
        print("-- Integration (SKIPPED — no Chrome/Chromium found) --")

    print()
    print(
        "Results: "
        + String(passed)
        + " passed, "
        + String(failed)
        + " failed, "
        + String(passed + failed)
        + " total"
    )
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")

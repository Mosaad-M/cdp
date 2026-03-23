# CLAUDE.md — CDP Module

## Overview

Chrome DevTools Protocol (CDP) client for Mojo. Launches headless Chrome, connects via WebSocket, and provides Browser/Page abstractions for navigation, JS evaluation, and DOM queries.

## Files

| File | Purpose |
|------|---------|
| `cdp.mojo` | Browser + Page structs, CDP command/response over WebSocket |
| `test_cdp.mojo` | 4 tests (2 unit, 2 integration requiring Chrome) |
| `pixi.toml` | Build config with compile-ssl task |

## Architecture

```
Chrome (headless) ──HTTP──> /json (targets list via curl)
Chrome (headless) ──WS───> CDP commands as JSON over WebSocket
```

- **Browser**: Launches Chrome with `--remote-debugging-port`, verifies via `/json/version`
- **Page**: Connects to a target's WebSocket URL, sends CDP commands, waits for matching response IDs
- Uses `curl` via `popen` FFI for HTTP (avoids Connection: keep-alive issues with Chrome's devtools server)
- Uses existing WebSocket + JSON modules for CDP message transport

## Symlinks

```
websocket.mojo -> ../websocket/websocket.mojo
url.mojo -> ../url/url.mojo
json.mojo -> ../json/json.mojo
tcp.mojo -> ../tcp/tcp.mojo
tls.mojo -> ../tls/tls.mojo
ssl_wrapper.c -> ../tls/ssl_wrapper.c
.build_tools -> ../tls/.build_tools
build_and_run.sh -> ../tls/build_and_run.sh
```

## Commands

```bash
pixi run test     # Compile + run tests (integration tests need Chrome)
pixi run format   # Format with mblack
```

## CDP Message Flow

1. `Browser.launch()` → spawns `google-chrome --headless=new --remote-debugging-port=9222`
2. `browser.get_targets()` → `curl http://localhost:9222/json` → JSON array of targets
3. `Page.connect_to_target(ws_url)` → WebSocket connect + `Page.enable`
4. `page.navigate(url)` → `{"method":"Page.navigate","params":{"url":"..."}}`
5. `page.wait_for_load()` → waits for `Page.loadEventFired` event
6. `page.evaluate(js)` → `Runtime.evaluate` → extracts result value

## Tests

- **Unit** (no Chrome): Browser/Page default init values
- **Integration** (requires Chrome): launch + get targets, navigate data URI + evaluate JS + query DOM
- Integration tests auto-skip if Chrome/Chromium not found

## Key Patterns

- `_curl_get()` uses `popen`/`fread`/`pclose` FFI for HTTP GET (Chrome's devtools HTTP server doesn't honor `Connection: close`)
- `_send_command()` sends JSON with incrementing `id`, reads WebSocket frames until matching response
- Events (no `id` field) are silently skipped while waiting for command responses
- `evaluate()` escapes quotes/backslashes/newlines in JS expressions

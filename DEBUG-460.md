# #460 IOCP crash — Windows VM / WinDbg TTD runbook

Intermittent crash on Windows/IOCP (ReleaseSafe): the scheduler dereferences a
garbage task in `getNextTask` (`runtime.zig`), because
`main_executor.pending_cleanup.tag` gets stomped to `1` (`.reschedule`) while its
payload is left untouched.

## What is known / ruled out

- **Destination (certain):** `&main_executor.pending_cleanup + 8` (the tag word,
  `exec + 0xbd8`). The write sets that 8-byte word to `1` and leaves the payload
  word (`exec + 0xbd0`) intact — a **tag-only** write, not a full
  `pending_cleanup = .{.reschedule = task}` assignment.
- **Source: UNKNOWN.** Ruled out via CI instrumentation: executor-thread scheduler
  writes; reused stack/task/Runtime memory; `WaitQueue`/`Notify`/`Async`
  primitives; leaked overlapped I/O at teardown (`inflight_io == 0`); DNS +
  process-wait callback-after-free (heap canaries); OVERLAPPED / OVERLAPPED_ENTRY
  size overrun (comptime asserts + runtime canaries). A hardware-watchpoint could
  never cleanly separate the corrupt write from legit `.none`/`yield` tag stores.
- Trigger needs the **full suite** (disappears with `TEST_FILTER=net.test`); the
  crash lands in `net.test.tcpConnectToHost: basic`, which does a DNS lookup.

Real fixes already landed on this branch (keep): `iocp.zig` overlapped byte/flags
out-params moved off the submit-frame stack; `dns/windows.zig` completion routed
through the loop + refcounted context.

## Build the test binary (with symbols)

On the Windows VM (native), from the repo root:

```
zig build test -Dbackend=iocp -Demit-test-bin
```

This emits the test executable + `.pdb` under `zig-out/` (or the cache). Build
ReleaseSafe to match CI: add `-Doptimize=ReleaseSafe`.

## Reproduce

Run the emitted `test.exe` (runs the full suite). It usually crashes within 1–2
runs. When it does, it prints, right before the panic:

```
DBG WATCH ADDR (pending_cleanup.tag) = 0x<ADDR>
```

That `<ADDR>` is the exact 8-byte word to watch.

## Catch the writer — WinDbg Time Travel Debugging (preferred)

1. Record:
   ```
   ttd.exe -out trace.run test.exe
   ```
   (or WinDbg Preview → Launch executable (advanced) → "Record with TTD".) Let it
   run until the panic.
2. Open `trace.run` in WinDbg. Go to the end / the panic. The crashing address is
   the `DBG WATCH ADDR` value (or, at `dbgCheckPC`, `&self.pending_cleanup + 8`).
3. Set a data breakpoint on it and reverse-execute to the writer:
   ```
   ba w8 0x<ADDR>
   g-
   ```
   TTD stops on the exact instruction that wrote the `1`, with full symbolized
   stack and thread — that is the culprit.

## Alternative — live WinDbg data breakpoint

If TTD is unavailable, break at the crashing runtime's `Runtime.init`, grab
`&rt.main_executor.pending_cleanup + 8`, then:

```
ba w8 0x<ADDR> ".if (poi(0x<ADDR>) == 1) { .echo CORRUPT; k } .else { gc }"
```

You inspect the faulting instruction's operands directly — no need to distinguish
legit `.none`/`yield` stores by hand.

## Complementary — PageHeap (if it turns out to be a UAF after all)

```
gflags /p /enable test.exe /full
```

Puts every heap allocation on its own guard-paged region so a write to
freed/overrun memory AVs at the writer. Run alongside the suite.

# ZIO Security & Correctness Audit

Audit performed by 6 parallel subagents across runtime/coroutines, event loop/backends,
I/O/net/fs, sync primitives, DNS, and time/OS. Status column tracks our review.

Status legend: `[ ]` not reviewed · `[~]` in progress · `[x]` resolved/accepted · `[-]` rejected/won't-fix

---

## 🔴 CRITICAL

### C1. Stack buffer overflow in `UnixAddress.init` on macOS/BSD — VERIFIED
- **Status:** [x] Fixed — `max_len` now derived from `sun_path` size minus NUL byte (net.zig:633). Also resolves M5.
- **File:** `src/net.zig:633-639`
- `max_len` is hard-coded to 108 (Linux size), but `sockaddr.un.path` is `[104]u8` on
  Darwin and the BSDs. A path of length 105–108 passes the `if (path.len > max_len)` guard,
  then `@memcpy(un.path[0..path.len], path)` overflows `un.path` by up to 4 bytes.
  Panic in safe builds (DoS); real stack overflow in ReleaseFast/Small. Reachable from
  `net.listen`/`net.connect` with user-controlled socket paths. No NUL byte reserved even on Linux.
- **Fix:** derive bound from the field, e.g.
  `const max_len = @typeInfo(@FieldType(sockaddr.un, "path")).array.len - 1;`
  and reject `path.len >= path_field_len`.

---

## 🟠 HIGH

### H1. DNS resolver: OOB slice / panic on over-long `name` — VERIFIED
- **Status:** [x] Fixed — length guard at top of `Resolver.lookup` rejects name > HostName.max_len with UnknownHostName (resolver.zig). Covers the canonical-name slices and CacheKey @intCast.
- **File:** `src/dns/resolver/resolver.zig:160, 172, 199` (+ `cache.zig:31-33`)
- Prefill copy is clamped (`@min(options.name.len, buf.len)` at :148), but returned
  canonical-name slices are not: `buf[0..options.name.len]` slices past the 255-byte buffer
  when name > 255. `Resolver.lookup`/`dns.lookup` are public and don't validate name length
  (only `HostName` does). `CacheKey.init`'s `assert(name.len <= 255)` compiles out in release,
  leaving `@intCast` to panic or silently truncate the cache key.
- **Fix:** reject `options.name.len > 255` at top of `lookup`; clamp every
  `buf[0..options.name.len]` to `buf[0..len]`.

### H2. IOCP multi-loop completion queue not thread-safe
- **Status:** [-] REJECTED — false positive. `markCompleted`'s `self.completions.push` uses the
  *polling* loop's own LoopState (threaded unchanged through poll→processCompletion→markCompleted),
  so a loop only ever pushes onto its own queue. Completions hand off via the kernel-synchronized
  IOCP port; whichever loop dequeues one fully owns post-processing on its own thread. The only
  shared mutable state (inflight/active counters) already routes to `shared.*` atomics
  (loop.zig:234-276). No cross-loop queue access.
- **File:** `src/ev/backends/iocp.zig:2024-2061` + `src/ev/loop.zig:289-332`
- IOCP advertises `is_multi_threaded`; multiple loops share one IOCP port.
  `GetQueuedCompletionStatusEx` on loop B can dequeue loop A's completion, then push onto B's
  non-atomic `completions` queue and run A's callback on B's thread. Only `active`/`inflight`
  counters were made shared atomics; the queues and callback dispatch were not. Heap corruption
  under multi-loop config.
- **Confidence:** medium — depends on whether multi-loop-per-port is a supported mode.
- **Fix:** either post completions back to the owning loop, or document/enforce one loop per IOCP port.

### H3. Windows path traversal + interior-NUL truncation
- **Status:** [-] DOWNGRADED to LOW / mostly rejected.
  - (b) `..` containment: NOT a bug. Consistent with POSIX openat (which also escapes without
    RESOLVE_BENEATH); `resolve_beneath` is documented Windows-unsupported (warns, or strict→Unsupported)
    at os/fs.zig:596-598. By design.
  - (a) interior-NUL truncation: real but NOT Windows-specific. POSIX `openat` uses
    `dupeSentinel(u8, path, 0)` (os/fs.zig:656) which also truncates at an embedded NUL. zio uniformly
    accepts embedded NUL on all platforms. LOW-severity hardening gap (null-byte injection vs a caller's
    suffix check); `std.posix.toPosixPath` rejects it, so there's precedent. Optional fix: reject interior
    NUL with error.BadPathName in the shared path-prep path.
- **File:** `src/os/windows.zig` `pathToWide`/`utf8ToWide` (~1161-1230)
- Dir-relative paths joined onto a `\\?\`-prefixed real path by raw string concat. The `\\?\`
  prefix disables kernel path normalization, so `..` is not collapsed — dir-scoped ops can escape
  the intended directory (unlike the `openat` model emulated). Also `utf8ToWide` converts by
  length, so an embedded `\x00` becomes interior NUL and `CreateFileW` opens the truncated prefix
  (`secret\x00.txt` → `secret`). `resolve_beneath` silently ignored unless mode is `.strict`.
- **Fix:** reject interior NUL; enforce `..` containment for dir-relative joins (or document no sandboxing).

### H4. `MSG_TRUNC` receive returns an oversized slice
- **Status:** [-] REJECTED — matches std.Io reference exactly. std.Io.Threaded netReceivePosix does the
  identical `data_buffer[0..@intCast(rc)]` (Threaded.zig:12915) with MSG_TRUNC passed as input flag.
  zio faithfully implements the std.Io interface; `.trunc` is opt-in and the "caller sizes the buffer"
  contract is documented (IncomingMessage.Flags.trunc signals truncation). Clamping would diverge from
  the interface zio conforms to. Leave as-is.
- **File:** `src/io.zig:2364-2373`
- With `flags.trunc`, Linux returns the full datagram length; code slices
  `data_buffer[0..result.len]` verbatim. If `result.len > data_buffer.len`, caller gets a slice
  past the buffer (OOB read).
- **Fix:** `data_buffer[0..@min(result.len, data_buffer.len)]`; report truncation via flags.

### H5. Data race: `last_run_tick` written cross-thread without synchronization
- **Status:** [-] REJECTED — false positive. last_run_tick (non-atomic) is guarded by the task.state
  atomic's release/acquire (park-token protocol). Home writes last_run_tick (runtime.zig:473) before the
  release CAS to .waiting (603-604, .acq_rel); the migrating waker's acquire load (506) sees .waiting and
  thus happens-after that write. Post-migration the field is single-thread-owned (ready_queue is a
  non-concurrent SimpleQueue, scheduleTaskLocal is same-thread). Standard non-atomic-guarded-by-atomic
  pattern; TSan tracks the HB edge and won't flag it.
- **File:** `src/runtime.zig:554` (read at :466/:473), field at `src/task.zig:165`
- Migration path writes plain (non-atomic) `u32 last_run_tick = 0` from the waking/stealing
  executor while the home executor reads/writes it in `getNextTask`. No documented happens-before
  edge — torn/stale reads under TSan; breaks "run once per tick" invariant.
- **Fix:** make atomic (monotonic), or assert+document exclusive-ownership invariant.

---

## 🟡 MEDIUM

### M1. Cross-backend error inconsistency for `net_poll` / `recvmsg`
- **Status:** [-] REJECTED — false positive. All four backends treat EOF/HUP/POLLERR as "ready→success"
  for net_poll: io_uring errors only on negative errno (POLLERR is a positive mask bit, io_uring.zig:941);
  epoll (703) and poll (644) treat ERR/HUP as success; kqueue (592) treats plain EOF as success and errors
  only on a genuine pending SO_ERROR (handleKqueueError, 446-461). Agent's claims ("io_uring errors on
  POLLERR", "kqueue errors on EOF") are factually wrong. Only divergence: kqueue surfaces a real SO_ERROR
  at poll time vs epoll/poll deferring to next I/O — intentional per kqueue.zig:593-595. The RecvFlags.trunc
  dropped-on-Windows sliver is a documented platform limitation.
- **File:** `io_uring.zig:941`, `kqueue.zig:592`, `epoll.zig:703`, `iocp.zig:637`
- io_uring and kqueue can return an error on EOF/HUP/POLLERR where epoll/poll report
  ready-with-success. Same logical event → different zio result by platform. Also `RecvFlags.trunc`
  silently dropped on Windows (`iocp.zig:637`).
- **Fix:** make `net_poll` treat poll-mask results as success consistently; align EOF/HUP handling.

### M2. io_uring waker can be permanently disarmed
- **Status:** [-] REJECTED — false positive; agent inverted the logic. armWaker sets
  waker_needs_rearm=false only AFTER a successful get_sqe (io_uring.zig:209); on failure it returns false
  at :205 with the flag STILL true, so the next poll() retries (:750, effective_timeout=.zero drains the
  SQ first). Init starts flag=true (:181) and a fresh ring's get_sqe always succeeds. No permanent disarm,
  no lost wakeups — self-healing by design (comments at :200-202, :746-749).
- **File:** `src/ev/backends/io_uring.zig:188`
- Init-time `armWaker()` result discarded with `_ =`; if it fails (SQ full), `waker_needs_rearm`
  stays false and `wake()` is never observed → lost wakeups/hangs.
- **Fix:** set `waker_needs_rearm = true` on any failed arm.

### M3. `Group` is effectively single-use but documented as reusable
- **Status:** [ ]
- **File:** `src/group.zig:192-219`
- `cancel()`/`wait()` leave `closed`/`failed`/`canceled` bits sticky; "Clear the canceled flag
  for reuse" comment is misleading — new spawns get `error.Closed`.
- **Fix:** reset the bits in `cancel()`/`reset()`, or fix the docs (single-use).

### M4. `nanosToFileTime` unchecked cast
- **Status:** [ ]
- **File:** `src/os/windows.zig:~314`
- Negative/pre-1601 timestamps from `fileSetTimestamps` panic (safe) or wrap (release).
- **Fix:** validate/clamp range, return error on out-of-range.

### M5. Unix path not NUL-terminated at max length
- **Status:** [x] Fixed together with C1 — `max_len` now reserves a byte for the NUL terminator.
- **File:** `src/net.zig:637`
- Even on Linux a 108-byte path has no terminator; kernel reads adjacent struct bytes.
  (Related to C1; fixing C1's bound to reserve 1 byte resolves this.)

### M6. DNS response question section never matched against the query
- **Status:** [ ]
- **File:** `src/dns/resolver/message.zig:164`
- Spoofing defense rests only on 16-bit txn ID + source endpoint; canonical name taken from the
  answer's owner name unvalidated (RFC 5452 recommends echoing qname/qtype/qclass).
- **Fix:** verify first question name/type/class matches the outgoing query before accepting answers.

### M7. `os/time.zig sleep()` swallows all unexpected errno
- **Status:** [ ]
- **File:** `src/os/time.zig:99-107` (riscv32 branch :87-94)
- A spurious `EINVAL`/`EFAULT` makes `sleep()` return immediately as if successful.
- **Fix:** panic/assert on unexpected errno like `now()` does.

### M8. Potential spin in Windows `dirReadImpl`
- **Status:** [ ]
- **File:** `src/io.zig:1233`
- A filename too long for a small caller buffer can loop with no forward progress (DoS hang).
- **Fix:** if `next()` returns null with `entry_index == 0` and no syscall progress, error/grow instead of looping.

---

## 🟢 LOW / quality

### L1. `blocking_task.zig` cancellation is a no-op
- **Status:** [ ]
- **File:** `src/blocking_task.zig:46`
- Cancel sets `user_canceled` but actual thread-pool cancel is commented out (TODO). Callers
  relying on cancel get silent non-cancellation.
- **Fix:** wire up `thread_pool.cancel`, or document blocking tasks as non-cancellable.

### L2. Darwin/DragonFly futex timeouts silently truncate long durations
- **Status:** [ ]
- **File:** `src/os/thread.zig:304-313` (Darwin), `545-553` (DragonFly)
- Durations >~35–71 min truncated. Safe only because all current callers loop on a deadline.
- **Fix:** document the loop requirement, or loop internally on residual timeout.

### L3. Wrong-arity dead `errdefer` in `AnyTask.create`
- **Status:** [x] Fixed — deleted the dead errdefer (nothing after acquire() is fallible); added a
  comment noting why no release-on-error is needed. task.zig.
- **File:** `src/task.zig:503`
- `release(self.coro.context.stack_info)` called with 1 arg; signature takes 3. Compiles only
  because the preceding `acquire()` is the last fallible op (errdefer body never analyzed). Latent
  compile breakage.
- **Fix:** `release(self.coro.context.stack_info, executor.runtime.now())` or remove the errdefer.

### L4. Misleading "acquire fence" comment in `Notify.wait`
- **Status:** [ ]
- **File:** `src/sync/Notify.zig:126`
- The flag referenced is never set on Notify; the real happens-before is via the Waiter's notify
  state. Comment is wrong/misleading.
- **Fix:** remove or correct the comment.

### L5. `RefCounter.incr` uses `.monotonic`
- **Status:** [ ]
- **File:** `src/utils/ref_counter.zig:67`
- Fine for owned-reference bumps, unsafe for lookup/resurrection patterns the doc implies.
- **Fix:** document the precondition (increment only from an existing live reference), or add an acquire variant.

---

## Flagged for stress tests (not confirmed bugs)

### T1. Channel direct-transfer cancel/timeout race
- **Status:** [ ]
- **File:** `src/sync/channel.zig` (`takeItemAndWakeSender` :105, transfer loops)
- `tryClaim()` always succeeds for direct waiters; interaction with a cancelling/timing-out
  receiver on an unbuffered channel is intricate. Couldn't confirm a lost item (shared mutex makes
  remove/pop mutually exclusive), but highest-risk under-tested area.
- **Action:** add stress test — cancel a blocked receiver while a sender does direct transfer (unbuffered + buffered).

### T2. `select` cleanup accounting
- **Status:** [ ]
- **File:** `src/select.zig:272-296, 360-378`
- `expected` decrement logic relies on `asyncCancelWait` returning exactly the right bool under
  concurrent completion. Couldn't construct a definite lost/extra signal.
- **Action:** add multi-threaded stress test with futures completing exactly at cancel time.

---

## External-input boundary sweep (targeted hunt for C1-class memory-safety bugs)

Verdict: input-boundary handling is, on the whole, well-bounded. The DNS wire parser's
`decodeName` (message.zig:101,105) checks every write against `out.len` and returns the actual
length, so the response canonical-name copy (resolver.zig:327,344) into the 255-byte buffer cannot
overflow. `parseIp6` keeps `index` even and ≤14; the `::` expansion memcpy fits exactly. recvfrom/
accept addresses use a full-sized union `.ip` reinterpret, not a length-driven slice. Control-message
data is handed to the caller raw (kernel guarantees controllen ≤ buffer). C1 was the genuine outlier.

Two LATENT items found (neither clearly live):

### S1. `Address.fromStorageIp` unchecked IP slice — DEAD CODE
- **Status:** [x] Fixed — deleted both fromStorage and fromStorageIp (zero references, never analyzed).
  Real address construction is kernel-writes-into-union + reinterpret, not these. net.zig.
- **File:** `src/net.zig:748-763`
- AF.INET/INET6 branches do `@memcpy(..., data[0..@sizeOf(sockaddr.in/in6)])` with no `data.len` check
  (the AF.UNIX branch in fromStorage clamps with @min). But `Address.fromStorage` has ZERO callers —
  dead code. If ever wired to a kernel-returned addr_len-sliced buffer, it's an OOB read.
- **Fix:** clamp like the UNIX branch, or delete the dead fromStorage/fromStorageIp.

### S2. dirent iterator: `reclen - offsetof` underflow + `reclen==0` infinite loop
- **Status:** [ ] latent / defense-in-depth
- **File:** `src/os/fs.zig:457` (extractName Linux), `:521` (isDotOrDotDot), `:428` (nextRaw)
- `max_len = entry.reclen - @offsetOf(dirent64,"name")` underflows to ~2^64 if a malformed record has
  `reclen < 19`, making `sliceTo` scan far past the buffer (OOB read). `reclen == 0` makes nextRaw not
  advance → infinite loop (DoS). Input is kernel getdents data; the Linux kernel computes/validates
  d_reclen even for FUSE (records reach userspace kernel-emitted), so not reachable in practice —
  pure robustness hardening.
- **Fix:** `if (entry.reclen < @offsetOf(...) ) break;` (and a `reclen == 0` guard in nextRaw).

## Repo hygiene

- **Status:** [ ]
- Stray `a.log` (32KB) and `test-file` in repo root look like leftover debris; not in `.gitignore`.

---

## Verified-solid areas (no action)

- DNS wire parser: compression-pointer loops depth-bounded; OOB reads bounds-checked.
- io_uring inflight/active accounting balanced across EINTR-deferral and cancel paths.
- Context-switch assembly clobber lists correct; `stackFaultHandler` async-signal-safe.
- `WaitQueue` flag-preserving remove/pop ordering; `popAndSetFlag` UAF-avoidance sound.
- `RefCounter.decr` acquire-load fence idiom correct.
- Time conversions saturating/overflow-safe; monotonic clocks used for all timeouts.

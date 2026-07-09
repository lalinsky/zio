// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT
//
// DEBUG(#460): hardware data-breakpoint watchpoint (Windows) to catch the thread
// that writes a stray `1` into executor.pending_cleanup.tag. We set DR0 on every
// thread (a monitor thread keeps re-applying it so on-demand threads — e.g. the
// Windows DNS thread pool — get it too) and a vectored exception handler dumps the
// faulting thread's instruction pointer + a frame-pointer stack walk on each hit.

const std = @import("std");
const builtin = @import("builtin");
const win = std.os.windows;

const DWORD = win.DWORD;
const HANDLE = win.HANDLE;
const BOOL = c_int;
const FALSE: BOOL = 0;

extern "kernel32" fn AddVectoredExceptionHandler(First: c_ulong, Handler: win.VECTORED_EXCEPTION_HANDLER) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetThreadContext(hThread: HANDLE, lpContext: *win.CONTEXT) callconv(.winapi) BOOL;
extern "kernel32" fn SetThreadContext(hThread: HANDLE, lpContext: *const win.CONTEXT) callconv(.winapi) BOOL;
extern "kernel32" fn OpenThread(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwThreadId: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn SuspendThread(hThread: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn ResumeThread(hThread: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn Thread32First(hSnapshot: HANDLE, lpte: *THREADENTRY32) callconv(.winapi) BOOL;
extern "kernel32" fn Thread32Next(hSnapshot: HANDLE, lpte: *THREADENTRY32) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
extern "kernel32" fn CreateThread(attr: ?*anyopaque, stack: usize, start: *const fn (?*anyopaque) callconv(.winapi) DWORD, param: ?*anyopaque, flags: DWORD, id: ?*DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn VirtualQuery(lpAddress: ?*const anyopaque, lpBuffer: *MEMORY_BASIC_INFORMATION, dwLength: usize) callconv(.winapi) usize;

const MEMORY_BASIC_INFORMATION = extern struct {
    BaseAddress: usize,
    AllocationBase: usize,
    AllocationProtect: DWORD,
    __alignment1: DWORD,
    RegionSize: usize,
    State: DWORD,
    Protect: DWORD,
    Type: DWORD,
    __alignment2: DWORD,
};

var corrupt_fired: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

const THREADENTRY32 = extern struct {
    dwSize: DWORD,
    cntUsage: DWORD,
    th32ThreadID: DWORD,
    th32OwnerProcessID: DWORD,
    tpBasePri: i32,
    tpDeltaPri: i32,
    dwFlags: DWORD,
};

const TH32CS_SNAPTHREAD: DWORD = 0x4;
const THREAD_GET_CONTEXT: DWORD = 0x8;
const THREAD_SET_CONTEXT: DWORD = 0x10;
const THREAD_SUSPEND_RESUME: DWORD = 0x2;
const CONTEXT_DEBUG_REGISTERS: DWORD = 0x00100000 | 0x00000010; // AMD64 | DEBUG_REGISTERS
const EXCEPTION_SINGLE_STEP: DWORD = 0x80000004;
const EXCEPTION_CONTINUE_EXECUTION: c_long = -1;
const EXCEPTION_CONTINUE_SEARCH: c_long = 0;

var watch_addr: usize = 0;
var self_pid: DWORD = 0;
var fired: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

var arm_count_logged: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// DR0 watches the tag word (watch_addr = pending_cleanup + 8); DR1 watches the
// payload word (watch_addr - 8). Dr7: L0|L1 enabled, both RW=01 (write), LEN=10 (8B).
const DR7_VALUE: u64 = 0x1 | 0x4 | (@as(u64, 0b01) << 16) | (@as(u64, 0b10) << 18) | (@as(u64, 0b01) << 20) | (@as(u64, 0b10) << 22);

fn setDrOn(h: HANDLE) bool {
    var ctx: win.CONTEXT = std.mem.zeroes(win.CONTEXT);
    ctx.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    if (GetThreadContext(h, &ctx) == FALSE) return false;
    if (ctx.Dr0 == watch_addr and ctx.Dr7 == DR7_VALUE) return true; // already armed
    ctx.Dr0 = watch_addr; // tag word (0xbd8)
    ctx.Dr1 = watch_addr - 8; // payload word (0xbd0)
    ctx.Dr7 = DR7_VALUE;
    ctx.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    return SetThreadContext(h, &ctx) != FALSE;
}

fn armAllThreads() void {
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snap == win.INVALID_HANDLE_VALUE) return;
    defer _ = CloseHandle(snap);
    var te: THREADENTRY32 = undefined;
    te.dwSize = @sizeOf(THREADENTRY32);
    const cur = GetCurrentThreadId();
    var armed: u32 = 0;
    var total: u32 = 0;
    if (Thread32First(snap, &te) == FALSE) return;
    while (true) {
        if (te.th32OwnerProcessID == self_pid and te.th32ThreadID != cur) {
            total += 1;
            if (OpenThread(THREAD_GET_CONTEXT | THREAD_SET_CONTEXT | THREAD_SUSPEND_RESUME, FALSE, te.th32ThreadID)) |h| {
                _ = SuspendThread(h);
                if (setDrOn(h)) armed += 1;
                _ = ResumeThread(h);
                _ = CloseHandle(h);
            }
        }
        if (Thread32Next(snap, &te) == FALSE) break;
    }
    // Log the armed/total once we've seen more than the main thread, so we know
    // whether background threads (DNS thread pool etc.) actually get the DR.
    if (total >= 2 and arm_count_logged.swap(1, .monotonic) == 0) {
        std.log.info("DBG(#460) watchpoint armed {}/{} background threads", .{ armed, total });
    }
}

fn monitor(_: ?*anyopaque) callconv(.winapi) DWORD {
    while (true) {
        armAllThreads();
        Sleep(1);
    }
}

var main_tid: DWORD = 0;
var seen: [32]usize = @splat(0);
var seen_n: usize = 0;
var seen_mutex: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

const sentinel: usize = 0xD00DFEEDD00DFEED;

const TF: u32 = 0x100; // EFLAGS trap flag (single-step)
threadlocal var ss_active: bool = false;
threadlocal var ss_candidate_rip: usize = 0;
threadlocal var ss_steps: u32 = 0;

fn reportCorruptor(rip: usize) void {
    while (seen_mutex.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    var found = false;
    var i: usize = 0;
    while (i < seen_n) : (i += 1) {
        if (seen[i] == rip) {
            found = true;
            break;
        }
    }
    if (!found and seen_n < seen.len) {
        seen[seen_n] = rip;
        seen_n += 1;
    }
    seen_mutex.store(0, .release);
    if (!found) {
        std.log.info("!!! CORRUPTOR (tag store, no payload store) thread={} rip=0x{x}", .{ GetCurrentThreadId(), rip });
        var addrs = [_]usize{rip};
        const trace = std.debug.StackTrace{ .return_addresses = &addrs, .skipped = .none };
        std.debug.dumpStackTrace(&trace);
    }
}

fn veh(info: *win.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    const rec = info.ExceptionRecord;
    if (rec.ExceptionCode != EXCEPTION_SINGLE_STEP) return EXCEPTION_CONTINUE_SEARCH;
    const ctx = info.ContextRecord;
    const dr6 = ctx.Dr6;
    ctx.Dr6 = 0;
    // No memory reads here (a stale/reused watch_addr must never fault the VEH).
    // A legit yield(.reschedule) stores the tag (DR0=0xbd8) and then IMMEDIATELY
    // the payload (DR1=0xbd0). The corruptor stores only the tag. So after a tag
    // store, single-step a few instructions: if the payload store fires (DR1),
    // it's a legit yield; if not, it's the standalone corruptor.
    if (ss_active) {
        if ((dr6 & 0x2) != 0) { // payload store followed → legit yield
            ss_active = false;
            ctx.EFlags &= ~TF;
            return EXCEPTION_CONTINUE_EXECUTION;
        }
        ss_steps += 1;
        if (ss_steps >= 6) { // no payload store → corruptor
            reportCorruptor(ss_candidate_rip);
            ss_active = false;
            ctx.EFlags &= ~TF;
            return EXCEPTION_CONTINUE_EXECUTION;
        }
        ctx.EFlags |= TF; // keep single-stepping
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if ((dr6 & 0x1) != 0) { // tag store (0xbd8) — start the follow check
        ss_candidate_rip = ctx.Rip;
        ss_steps = 0;
        ss_active = true;
        ctx.EFlags |= TF;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if ((dr6 & 0xf) != 0) return EXCEPTION_CONTINUE_EXECUTION; // lone payload store, ignore
    return EXCEPTION_CONTINUE_SEARCH;
}

var installed = std.atomic.Value(bool).init(false);

/// Arm a hardware write watchpoint on `addr` (8-byte). Windows-only, debug use.
pub fn arm(addr: usize) void {
    if (builtin.os.tag != .windows) return;
    watch_addr = addr; // updated per-runtime; monitor/VEH use the latest
    if (installed.swap(true, .acq_rel)) return; // install VEH + monitor once
    main_tid = GetCurrentThreadId();
    self_pid = GetCurrentProcessId();
    _ = AddVectoredExceptionHandler(1, veh);
    // The monitor thread arms DR0 on every thread (including this one and any
    // on-demand threads such as the Windows DNS thread pool).
    _ = CreateThread(null, 0, monitor, null, 0, null);
}

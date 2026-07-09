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

fn setDrOn(h: HANDLE) void {
    var ctx: win.CONTEXT = std.mem.zeroes(win.CONTEXT);
    ctx.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    if (GetThreadContext(h, &ctx) == FALSE) return;
    if (ctx.Dr0 == watch_addr and (ctx.Dr7 & 0x1) != 0) return; // already armed
    ctx.Dr0 = watch_addr;
    // L0 enable | RW0=01 (write) | LEN0=10 (8 bytes)
    ctx.Dr7 = 0x1 | (@as(u64, 0b01) << 16) | (@as(u64, 0b10) << 18);
    ctx.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    _ = SetThreadContext(h, &ctx);
}

fn armAllThreads() void {
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snap == win.INVALID_HANDLE_VALUE) return;
    defer _ = CloseHandle(snap);
    var te: THREADENTRY32 = undefined;
    te.dwSize = @sizeOf(THREADENTRY32);
    const cur = GetCurrentThreadId();
    if (Thread32First(snap, &te) == FALSE) return;
    while (true) {
        if (te.th32OwnerProcessID == self_pid and te.th32ThreadID != cur) {
            if (OpenThread(THREAD_GET_CONTEXT | THREAD_SET_CONTEXT | THREAD_SUSPEND_RESUME, FALSE, te.th32ThreadID)) |h| {
                _ = SuspendThread(h);
                setDrOn(h);
                _ = ResumeThread(h);
                _ = CloseHandle(h);
            }
        }
        if (Thread32Next(snap, &te) == FALSE) break;
    }
}

fn monitor(_: ?*anyopaque) callconv(.winapi) DWORD {
    while (true) {
        armAllThreads();
        Sleep(5);
    }
}

var main_tid: DWORD = 0;

fn veh(info: *win.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    const rec = info.ExceptionRecord;
    if (rec.ExceptionCode != EXCEPTION_SINGLE_STEP) return EXCEPTION_CONTINUE_SEARCH;
    const ctx = info.ContextRecord;
    if ((ctx.Dr6 & 0xf) == 0) return EXCEPTION_CONTINUE_SEARCH;
    ctx.Dr6 = 0; // clear detection bits
    // The DR fires on EVERY write to pending_cleanup.tag. Legit writes (yield /
    // processCleanup / the create() memset) are all on the main/executor thread.
    // The corruptor is a *background* thread — filter by thread id. No memory reads
    // here (the address may be a freed runtime), just the instruction pointer.
    if (GetCurrentThreadId() != main_tid) {
        const n = fired.fetchAdd(1, .monotonic);
        if (n < 8) {
            std.log.info("CORRUPT WRITE (bg thread={}) rip=0x{x}", .{ GetCurrentThreadId(), ctx.Rip });
            var addrs = [_]usize{ctx.Rip};
            const trace = std.debug.StackTrace{ .return_addresses = &addrs, .skipped = .none };
            std.debug.dumpStackTrace(&trace);
        }
    }
    return EXCEPTION_CONTINUE_EXECUTION;
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

//! Low-level event loop primitives.
//!
//! This module provides a callback-based async I/O event loop, similar to libuv or libxev.
//! For most use cases, prefer `zio.Runtime` which provides coroutines,
//! structured concurrency, and easier I/O.
//!
//! Use this module when you need:
//! - Callback-based async instead of coroutines
//! - Building a custom scheduler/runtime on top of zio.ev
//! - Embedding in a game loop or other custom run loops

const std = @import("std");

pub const backend = @import("backend.zig").backend;
pub const Backend = @import("backend.zig").Backend;

pub const Loop = @import("loop.zig").Loop;
pub const RunMode = @import("loop.zig").RunMode;
pub const ThreadPool = @import("thread_pool.zig").ThreadPool;

pub const ReadBuf = @import("buf.zig").ReadBuf;
pub const WriteBuf = @import("buf.zig").WriteBuf;

pub const executeBlocking = @import("blocking.zig").executeBlocking;

const completion = @import("completion.zig");
pub const Completion = completion.Completion;
pub const Op = completion.Op;
pub const Cancelable = completion.Cancelable;
pub const Group = completion.Group;
pub const Timer = completion.Timer;
pub const Async = completion.Async;
pub const Work = completion.Work;
pub const NetOpen = completion.NetOpen;
pub const NetBind = completion.NetBind;
pub const NetListen = completion.NetListen;
pub const NetConnect = completion.NetConnect;
pub const NetAccept = completion.NetAccept;
pub const NetRecv = completion.NetRecv;
pub const NetSend = completion.NetSend;
pub const NetRecvFrom = completion.NetRecvFrom;
pub const NetSendTo = completion.NetSendTo;
pub const NetRecvMsg = completion.NetRecvMsg;
pub const NetSendMsg = completion.NetSendMsg;
pub const NetPoll = completion.NetPoll;
pub const NetClose = completion.NetClose;
pub const NetShutdown = completion.NetShutdown;
pub const FileOpen = completion.FileOpen;
pub const FileCreate = completion.FileCreate;
pub const FileClose = completion.FileClose;
pub const FileRead = completion.FileRead;
pub const FileWrite = completion.FileWrite;
pub const FileSync = completion.FileSync;
pub const FileSetSize = completion.FileSetSize;
pub const FileSetPermissions = completion.FileSetPermissions;
pub const FileSetOwner = completion.FileSetOwner;
pub const FileSetTimestamps = completion.FileSetTimestamps;
pub const DirCreateDir = completion.DirCreateDir;
pub const DirRename = completion.DirRename;
pub const DirRenamePreserve = completion.DirRenamePreserve;
pub const DirDeleteFile = completion.DirDeleteFile;
pub const DirDeleteDir = completion.DirDeleteDir;
pub const FileSize = completion.FileSize;
pub const FileStat = completion.FileStat;
pub const DirOpen = completion.DirOpen;
pub const DirClose = completion.DirClose;
pub const DirRead = completion.DirRead;
pub const DirSetPermissions = completion.DirSetPermissions;
pub const DirSetOwner = completion.DirSetOwner;
pub const DirSetFilePermissions = completion.DirSetFilePermissions;
pub const DirSetFileOwner = completion.DirSetFileOwner;
pub const DirSetFileTimestamps = completion.DirSetFileTimestamps;
pub const DirSymLink = completion.DirSymLink;
pub const DirReadLink = completion.DirReadLink;
pub const DirHardLink = completion.DirHardLink;
pub const DirAccess = completion.DirAccess;
pub const DirRealPath = completion.DirRealPath;
pub const DirRealPathFile = completion.DirRealPathFile;
pub const FileRealPath = completion.FileRealPath;
pub const FileHardLink = completion.FileHardLink;
pub const PipePoll = completion.PipePoll;
pub const PipeCreate = completion.PipeCreate;
pub const PipeRead = completion.PipeRead;
pub const PipeWrite = completion.PipeWrite;
pub const PipeClose = completion.PipeClose;

test {
    std.testing.refAllDecls(@This());
}

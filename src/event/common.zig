/// The loop run mode -- all backends are required to support this in some way.
/// Backends may provide backend-specific APIs that behave slightly differently
/// or in a more configurable way.
pub const RunMode = enum(c_int) {
    /// Run the event loop once. If there are no blocking operations ready,
    /// return immediately.
    no_wait = 0,

    /// Run the event loop once, waiting for at least one blocking operation
    /// to complete.
    once = 1,

    /// Run the event loop until it is "done". "Doneness" is defined as
    /// there being no more completions that are active.
    until_done = 2,
};


//! the panic namespace every binary here installs: `std.debug.simple_panic`, with one function
//! replaced because 0.17.0's copy of it does not compile.
//!
//! `std.debug.simple_panic.unexpectedErrorCode` discards its argument with `_ = err;`, and 0.17
//! made discarding an error value an error — the same file gets it right one function earlier,
//! with `_ = &err;`. the result is that nothing targeting the device could be built at all, with
//! the compile error landing inside somebody else's std and naming none of our code.
//!
//! so this re-exports the namespace by hand and corrects that one function. the behaviour is
//! unchanged: the message and the trap are simple_panic's, which is what these binaries want —
//! `std.debug.FullPanic` formats its messages and drags std.fmt into six static binaries that
//! are size-audited. **delete this file and go back to `std.debug.simple_panic` as soon as a zig
//! release fixes it**; the only thing it has to say is `_ = &err;`.

const std = @import("std");
const simple = std.debug.simple_panic;

pub const call = simple.call;
pub const sentinelMismatch = simple.sentinelMismatch;
pub const unwrapError = simple.unwrapError;
pub const outOfBounds = simple.outOfBounds;
pub const startGreaterThanEnd = simple.startGreaterThanEnd;
pub const inactiveUnionField = simple.inactiveUnionField;
pub const sliceCastLenRemainder = simple.sliceCastLenRemainder;
pub const reachedUnreachable = simple.reachedUnreachable;
pub const unwrapNull = simple.unwrapNull;
pub const castToNull = simple.castToNull;
pub const incorrectAlignment = simple.incorrectAlignment;
pub const invalidErrorCode = simple.invalidErrorCode;
pub const integerOutOfBounds = simple.integerOutOfBounds;
pub const integerOverflow = simple.integerOverflow;
pub const shlOverflow = simple.shlOverflow;
pub const shrOverflow = simple.shrOverflow;
pub const divideByZero = simple.divideByZero;
pub const exactDivisionRemainder = simple.exactDivisionRemainder;
pub const integerPartOutOfBounds = simple.integerPartOutOfBounds;
pub const corruptSwitch = simple.corruptSwitch;
pub const shiftRhsTooBig = simple.shiftRhsTooBig;
pub const invalidEnumValue = simple.invalidEnumValue;
pub const forLenMismatch = simple.forLenMismatch;
pub const copyLenMismatch = simple.copyLenMismatch;
pub const memcpyAlias = simple.memcpyAlias;
pub const noreturnReturned = simple.noreturnReturned;
pub const loadUninstantiableType = simple.loadUninstantiableType;

/// the one that does not compile upstream. same message, same trap.
pub fn unexpectedErrorCode(err: anyerror) noreturn {
    @branchHint(.cold);
    _ = &err;
    call("unexpected error code", null);
}

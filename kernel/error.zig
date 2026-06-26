// The single shared error set and its ABI mapping (06-kernel-ddd.md Section 4; 03-syscall-abi.md).

pub const Error = error{

    BadHandle,
    WrongType,
    NoMemory,
    NotAllowed,
    WouldBlock,
    NotFound,
    Invalid,
    Gone,
};

// Negative ABI codes, in the order 03-syscall-abi.md fixes (BadHandle = -1 .. Gone = -8).

fn code(err: Error) i64 {

    return switch (err) {

        error.BadHandle => -1,
        error.WrongType => -2,
        error.NoMemory => -3,
        error.NotAllowed => -4,
        error.WouldBlock => -5,
        error.NotFound => -6,
        error.Invalid => -7,
        error.Gone => -8,

    };

}

/// Map a result to the signed ABI return word: success values pass through, errors become their negative code.
pub fn to_abi(result: Error!u64) i64 {

    return if (result) |value| @bitCast(value) else |err| code(err);

}

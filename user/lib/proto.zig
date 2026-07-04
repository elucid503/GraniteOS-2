// Shared interface constants (07-userspace-ddd.md Section 3.4, Section 10; 05-server-protocol.md): word 0 is method in, status out; method 0 is always Identify; methods are append-only.

pub const identify: u16 = 0;

// The Stream interface (07-userspace-ddd.md Section 10.2), spoken by the console driver (and later pipes and
// terminals). `attach` extends the table with the per-session shared buffer setup of 05-server-protocol.md:
// the client shares one Region up front, and every read/write after that passes only offset/length into it.

pub const stream = struct {

    pub const interface_id: u32 = 0x5354_524d; // "STRM"
    pub const version: u32 = 1;

    pub const read: u16 = 1; // request: offset, capacity        reply: bytes read
    pub const write: u16 = 2; // request: offset, length          reply: bytes written
    pub const set_mode: u16 = 3; // request: mode                    reply: status
    pub const attach: u16 = 4; // request: capacity, buffer Region  reply: status

    pub const mode_raw: u64 = 0;
    pub const mode_cooked: u64 = 1;

};

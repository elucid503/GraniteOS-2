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

// Init message consumed by the runtime on cap.startup_endpoint before it calls the program's main.

pub const init = struct {

    pub const stdin_ring: u64 = 1 << 0;
    pub const stdout_ring: u64 = 1 << 1;
    pub const stderr_ring: u64 = 1 << 2;

};

// Name service interface (07-userspace-ddd.md Section 10.1), with M6 inline names.

pub const name = struct {

    pub const interface_id: u32 = 0x4e41_4d45; // "NAME"
    pub const version: u32 = 1;

    pub const max_length: usize = 32;

    pub const register: u16 = 1;
    pub const lookup: u16 = 2;
    pub const list: u16 = 3;
    pub const unregister: u16 = 4;

};

// The process-supervision (death) convention (07-userspace-ddd.md Section 10.4): a child's runtime `send`s a one-way
// death message here on exit; the spawner (Flint) receives these to reap and restart. The sender's badge
// identifies the child; data[1] carries its exit status.

pub const supervisor = struct {

    pub const death: u16 = 1; // request: exit status        (one-way; no reply)

};

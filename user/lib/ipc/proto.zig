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

    // Init message data[5]: the machine's discovered core count, threaded from Flint through Marble.
    pub const core_count_word: usize = 5;

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

// Block interface (07-userspace-ddd.md Section 10.5), spoken by the virtio-blk driver. `attach` extends the table
// with the per-session shared buffer setup of 05-server-protocol.md; sectors then ride at offsets into it.

pub const block = struct {

    pub const interface_id: u32 = 0x424c_4f4b; // "BLOK"
    pub const version: u32 = 1;

    pub const sector_size: usize = 512;

    pub const read_sector: u16 = 1; // request: sector, offset           reply: status
    pub const write_sector: u16 = 2; // request: sector, offset           reply: status
    pub const capacity: u16 = 3; // request: -                        reply: sector count
    pub const attach: u16 = 4; // request: capacity, buffer Region   reply: status

};

// Filesystem interface (07-userspace-ddd.md Section 10.3). Paths, file data, and result records ride in the
// per-session shared buffer as (offset, length) pairs; `attach` (appended) shares that buffer once.

pub const filesystem = struct {

    pub const interface_id: u32 = 0x4653_5652; // "FSVR"
    pub const version: u32 = 1;

    pub const open: u16 = 1; // request: path offset, path length, flags     reply: file id
    pub const close: u16 = 2; // request: file id                             reply: status
    pub const read: u16 = 3; // request: file id, file offset, buffer offset, length   reply: bytes read
    pub const write: u16 = 4; // request: file id, file offset, buffer offset, length   reply: bytes written
    pub const create: u16 = 5; // request: path offset, path length, kind      reply: status
    pub const delete: u16 = 6; // request: path offset, path length            reply: status
    pub const rename: u16 = 7; // request: old offset, old length, new offset, new length   reply: status
    pub const list: u16 = 8; // request: path offset, path length, buffer offset, capacity   reply: bytes written
    pub const stat: u16 = 9; // request: path offset, path length, buffer offset   reply: status
    pub const mkdir: u16 = 10; // request: path offset, path length            reply: status
    pub const set_permissions: u16 = 11; // request: path offset, path length, mask      reply: status
    pub const attach: u16 = 12; // request: capacity, buffer Region              reply: status

    pub const kind_file: u64 = 1;
    pub const kind_directory: u64 = 2;

    // open flags
    pub const open_create: u64 = 1; // create the file if it does not exist
    pub const open_truncate: u64 = 2; // drop existing contents

    // permissions mask bits (set_permissions / Stat.permissions)
    pub const permission_write: u64 = 1;

    /// What `stat` writes into the session buffer.
    pub const Stat = extern struct {

        kind: u32,
        permissions: u32,

        length: u64,

        created_ns: u64,
        modified_ns: u64,

    };

    /// One record in a `list` reply: a packed run of these fills the session buffer.
    pub const Entry = extern struct {

        inode: u32,

        kind: u8,
        name_len: u8,
        reserved: [2]u8,

        length: u64,

        name: [48]u8,

    };

};

// The process-supervision (death) convention (07-userspace-ddd.md Section 10.4): a child's runtime `send`s a one-way
// death message here on exit; the spawner (Flint) receives these to reap and restart. The sender's badge
// identifies the child; data[1] carries its exit status.

pub const supervisor = struct {

    pub const death: u16 = 1; // request: exit status        (one-way; no reply)

};

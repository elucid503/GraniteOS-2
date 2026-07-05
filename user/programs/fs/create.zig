// create: make an empty file through the filesystem server.

const lib = @import("lib");

comptime {

    _ = lib.start;

}

pub fn main(args: []const []const u8) u8 {

    return lib.fs.simple_path_program("create", args, do_create);

}

fn do_create(client: *lib.fs.Client, path: []const u8) lib.sys.Error!void {

    try client.create(path, lib.proto.filesystem.kind_file);

}

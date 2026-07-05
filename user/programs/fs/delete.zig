// delete: remove a file or empty directory through the filesystem server.

const lib = @import("lib");

comptime {

    _ = lib.start;

}

pub fn main(args: []const []const u8) u8 {

    return lib.fs.simple_path_program("delete", args, do_delete);

}

fn do_delete(client: *lib.fs.Client, path: []const u8) lib.sys.Error!void {

    try client.delete(path);

}

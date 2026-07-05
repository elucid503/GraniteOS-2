// mkdir: make a directory through the filesystem server.

const lib = @import("lib");

comptime {

    _ = lib.start;

}

pub fn main(args: []const []const u8) u8 {

    return lib.fs.simple_path_program("mkdir", args, do_mkdir);

}

fn do_mkdir(client: *lib.fs.Client, path: []const u8) lib.sys.Error!void {

    try client.mkdir(path);

}

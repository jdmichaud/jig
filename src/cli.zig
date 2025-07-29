const std = @import("std");
const jam = @import("jam");
const readline = @import("readline");
const history = @import("history");
const jig = @import("jig");

const stdout = std.io.getStdOut().writer();

pub fn get_command(allocator: std.mem.Allocator, history_file: []const u8) !?[]const u8 {
  _ = history.read_history(history_file.ptr);

  var is_multiline = false;
  var command: []u8 = try allocator.alloc(u8, 0);
  var command_length: usize = 0;
  while (true) {
    const line = if (is_multiline) readline.readline("... ") else readline.readline("> ");
    if (line == null) {
      try stdout.print("^D\n", .{});
      return null;
    }

    const line_length = std.mem.len(line);
    if (line_length == 0) {
      continue;
    }

    _ = history.add_history(line);

    if (is_multiline) {
      command = try allocator.realloc(command, command.len + line_length + 1);
      command_length += (try std.fmt.bufPrint(command[command_length..], "\n{s}", .{ line })).len;
    } else {
      command = try allocator.realloc(command, command.len + line_length);
      command_length += (try std.fmt.bufPrint(command[command_length..], "{s}", .{ line })).len;
    }

    // std.log.debug(" ->> >{s}<", .{ command });
    var parser = try jam.Parser.init(allocator, command, .{ .source_type = .script });
    defer parser.deinit();

    if (parser.parse()) |*ast| {
      // Not sure why we need a constCast here
      defer @constCast(ast).deinit();
      _ = history.write_history(history_file.ptr);
      return command;
    } else |_| {
      // We are multiline if the parsing fails on en unexpected empty token
      // which means there is nothing wrong with our line, it just does not
      // terminate.
      is_multiline = false;
      for (parser.diagnostics.items) |d| {
        if (std.mem.endsWith(u8, d.message, "got ")) {
          is_multiline = true;
          break;
        }
      }
      // If we are multiline, do not show error, just continue with this
      // variable set to true.
      if (is_multiline) {
        continue;
      }

      return command;
    }
  }
}

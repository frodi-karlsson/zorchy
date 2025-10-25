const std = @import("std");
const zorchy = @import("root.zig");
const logging = @import("logging.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        std.log.info("Usage: {s} <json-file>\n", .{args[0]});
        return;
    }

    const json_file_path = args[1];
    std.log.info("Zorchy Workflow Executor\nUsing JSON file: {s}\n", .{json_file_path});

    const json = try std.fs.cwd().readFileAlloc(try std.fs.realpathAlloc(allocator, json_file_path), allocator, std.Io.Limit.unlimited);
    defer allocator.free(json);

    var workFlow: zorchy.workflow.Workflow = try zorchy.json.unmarshalJSONWorkflow(allocator, json);
    workFlow.execute(allocator) catch |err| {
        std.log.err(logging.red("Workflow execution failed: {s}"), .{@errorName(err)});
        return err;
    };
}

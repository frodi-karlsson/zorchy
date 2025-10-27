const std = @import("std");
const task = @import("task.zig");
const workflow = @import("workflow.zig");

pub const JSONTaskError = error{
    UnknownTaskType,
};

pub const JSONShellTask = struct {
    command: []const u8,
    args: []const []const u8,
};

pub const JSONMockTask = struct {
    status: task.TaskStatus,
};

pub const AnyJSONTask = union(task.TaskType) {
    Shell: JSONShellTask,
    Mock: JSONMockTask,
};

pub const JSONWorkflowStep = struct {
    name: []const u8,
    task: AnyJSONTask,
    options: ?task.TaskOptions = null,
    onError: ?[]const u8 = null,
    dependsOn: ?[]const []const u8 = null,
};

pub const JSONRoot = struct {
    @"$schema": ?[]const u8 = null,
    workflows: []const JSONWorkflowStep,
    entryPoint: []const u8,
    concurrency: ?usize = null,
};

pub const JSONShellTaskError = error{
    MissingCommand,
};

pub const AnyTaskError = JSONTaskError || JSONShellTaskError;

fn unmarshalJSONStep(allocator: std.mem.Allocator, step: JSONWorkflowStep) std.mem.Allocator.Error!workflow.WorkflowStep {
    const unmarshalledTask = task: switch (step.task) {
        .Shell => |shellTask| {
            const command = try allocator.dupe(u8, shellTask.command);
            defer allocator.free(command);

            const args = try allocator.dupe([]const u8, shellTask.args);
            defer allocator.free(args);

            const createdTask = try task.Task.create(allocator, step.name, step.options orelse .{}, task.AnyTask{ .Shell = try task.ShellTask.create(allocator, command, args) });
            break :task createdTask;
        },
        .Mock => |mockTask| {
            const createdTask = try task.Task.create(allocator, step.name, step.options orelse .{}, task.AnyTask{ .Mock = task.MockTask.create(mockTask.status) });
            break :task createdTask;
        },
    };

    return try workflow.WorkflowStep.create(allocator, step.name, unmarshalledTask, step.onError, step.dependsOn);
}

/// Unmarshals a JSON workflow into a workflow.Workflow
pub fn unmarshalJSONWorkflow(allocator: std.mem.Allocator, json: []const u8) (AnyTaskError || std.json.ParseError(std.json.Scanner))!workflow.Workflow {
    const root: std.json.Parsed(JSONRoot) = try std.json.parseFromSlice(JSONRoot, allocator, json, .{});
    defer root.deinit();

    var steps = try std.ArrayList(workflow.WorkflowStep).initCapacity(allocator, root.value.workflows.len);
    defer steps.deinit(allocator);

    for (root.value.workflows) |workflow_step| {
        const step = try unmarshalJSONStep(allocator, workflow_step);
        try steps.append(allocator, step);
    }

    const stepsSlice = try steps.toOwnedSlice(allocator);
    defer allocator.free(stepsSlice);

    return try workflow.Workflow.create(stepsSlice, root.value.entryPoint, allocator, root.value.concurrency);
}

test "unmarshal JSON workflow" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\    "workflows": [
        \\    {
        \\        "name": "step1",
        \\        "task": {
        \\            "Shell": {
        \\              "command": "echo",
        \\              "args": ["Hello, World!"]
        \\            }
        \\        }
        \\    },
        \\    {
        \\        "name": "step2",
        \\        "task": {
        \\            "Shell": {
        \\              "command": "ls",
        \\              "args": ["-l", "/"]
        \\            }
        \\        }
        \\    }
        \\],
        \\"entryPoint": "step1"
        \\}
    ;

    var unmarshalled = try unmarshalJSONWorkflow(allocator, json);
    defer unmarshalled.deinit(allocator);

    try std.testing.expectEqualStrings("step1", unmarshalled.entryPoint);
    try std.testing.expectEqual(unmarshalled.steps.len, 2);

    const step1 = unmarshalled.steps[0];
    try std.testing.expectEqualStrings("step1", step1.name);
    const task1 = switch (step1.task.impl) {
        .Shell => |shellTask| shellTask,
        else => unreachable,
    };
    try std.testing.expectEqualStrings("echo", task1.command);
    try std.testing.expectEqual(task1.args.len, 1);
    try std.testing.expectEqualStrings("Hello, World!", task1.args[0]);

    const step2 = unmarshalled.steps[1];
    try std.testing.expectEqualStrings("step2", step2.name);
    const task2 = switch (step2.task.impl) {
        .Shell => |shellTask| shellTask,
        else => unreachable,
    };
    try std.testing.expectEqualStrings("ls", task2.command);
    try std.testing.expectEqual(task2.args.len, 2);
    try std.testing.expectEqualStrings("-l", task2.args[0]);
    try std.testing.expectEqualStrings("/", task2.args[1]);
}

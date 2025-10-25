const std = @import("std");
const builtin = @import("builtin");
const logging = @import("./logging.zig");

/// TaskStatus represents the current status of a task.
pub const TaskStatus = enum {
    /// The task is pending and has not started yet.
    Pending,
    /// The task is currently in progress.
    InProgress,
    /// The task has completed successfully.
    Completed,
    /// The task has failed.
    Failed,

    pub fn toString(self: TaskStatus) []const u8 {
        return switch (self) {
            .Pending => "Pending",
            .InProgress => "InProgress",
            .Completed => "Completed",
            .Failed => "Failed",
        };
    }
};

/// TaskDiagnostic holds diagnostic information for a task's context.
/// This includes a message and a timestamp.
pub const TaskDiagnostic = struct {
    /// Diagnostic message associated with the task.
    message: []u8,
    /// Timestamp of when the diagnostic was created.
    timestampMs: i64,

    pub fn free(self: *TaskDiagnostic, allocator: std.mem.Allocator) void {
        if (self.message.len > 0) {
            allocator.free(self.message);
            self.message = &[_]u8{};
        }
    }
};

test "TaskDiagnostic - free releases message memory" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.debug.print("Leaked memory in test allocator\n", .{});
    };
    const allocator = gpa.allocator();

    const msg = std.fmt.allocPrint(allocator, "{s}", .{"Test diagnostic message"}) catch {
        std.debug.print("Failed to allocate message\n", .{});
        return;
    };

    var diag = TaskDiagnostic{
        .message = msg,
        .timestampMs = std.time.milliTimestamp(),
    };

    diag.free(allocator);
}

/// TaskStatusChange represents a change in the status of a task.
pub const TaskStatusChange = struct {
    /// null for the first status change
    previous: ?TaskStatus,
    /// The new current status of the task.
    current: TaskStatus,
    /// Timestamp of when the status change occurred.
    timestampMs: i64,
};

/// TaskContext holds the context and state of a task.
/// This means it is not deinitialized when the task concludes,
/// so that diagnostics and status history can be inspected before
/// manual deinitialization.
/// Use the `create` function to create a new TaskContext, and
/// `deinit` to free its resources.
pub const TaskContext = struct {
    diagnostics: std.ArrayList(TaskDiagnostic),
    status: TaskStatus,
    statusChanges: std.ArrayList(TaskStatusChange),
    env: ?[][*:0]const u8,

    /// Deinitializes the TaskContext, freeing all associated resources.
    pub fn deinit(self: *TaskContext, allocator: std.mem.Allocator) void {
        while (self.diagnostics.items.len > 0) {
            var diag = self.diagnostics.pop();
            diag.?.free(allocator);
        }
        self.diagnostics.deinit(allocator);
        self.statusChanges.deinit(allocator);
    }

    /// Changes the status of the task and records the status change, returning the new status for convenience.
    pub fn changeStatus(self: *TaskContext, allocator: std.mem.Allocator, newStatus: TaskStatus) std.mem.Allocator.Error!TaskStatus {
        if (self.status == newStatus) {
            return self.status;
        }
        const statusChange = TaskStatusChange{
            .previous = if (self.statusChanges.items.len == 0) null else self.status,
            .current = newStatus,
            .timestampMs = std.time.milliTimestamp(),
        };
        try self.statusChanges.append(allocator, statusChange);
        self.status = newStatus;
        return self.status;
    }

    /// Creates a new TaskContext with initialized fields.
    pub fn create(allocator: std.mem.Allocator) std.mem.Allocator.Error!TaskContext {
        const diagnostics = try std.ArrayList(TaskDiagnostic).initCapacity(allocator, 4);
        const status = TaskStatus.Pending;
        const statusChanges = try std.ArrayList(TaskStatusChange).initCapacity(allocator, 4);
        return TaskContext{
            .diagnostics = diagnostics,
            .status = status,
            .statusChanges = statusChanges,
            .env = null,
        };
    }
};

/// TaskOptions holds configuration options for tasks. Unused so far.
pub const TaskOptions = struct {
    retryCount: u8 = 0,
    retryDelaySeconds: u16 = 0,
    retryMultiplier: f32 = 1.0,
    timeoutSeconds: u16 = 10,
};

fn addDiag(ctx: *TaskContext, allocator: std.mem.Allocator, message: []const u8) std.mem.Allocator.Error!void {
    var diag = TaskDiagnostic{
        .message = try allocator.dupe(u8, message),
        .timestampMs = std.time.milliTimestamp(),
    };

    errdefer diag.free(allocator);
    try ctx.diagnostics.append(allocator, diag);
}

test "addDiag appends diagnostic to context" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.debug.print("Leaked memory in test allocator\n", .{});
    };
    const allocator = gpa.allocator();

    var ctx = try TaskContext.create(allocator);
    defer ctx.deinit(allocator);

    try addDiag(&ctx, allocator, "Test diagnostic message");

    try std.testing.expectEqual(1, ctx.diagnostics.items.len);
    try std.testing.expectEqualStrings(ctx.diagnostics.items[0].message, "Test diagnostic message");
}

fn addErrDiag(ctx: *TaskContext, allocator: std.mem.Allocator, err: anyerror) std.mem.Allocator.Error!void {
    const message = try std.fmt.allocPrint(allocator, logging.red("Error: {s}"), .{@errorName(err)});
    var diag = TaskDiagnostic{
        .message = message,
        .timestampMs = std.time.milliTimestamp(),
    };
    errdefer diag.free(allocator);
    try ctx.diagnostics.append(allocator, diag);
}

test "TaskContext - create allocates context correctly" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.debug.print("Leaked memory in test allocator\n", .{});
    };
    const allocator = gpa.allocator();

    var ctx = try TaskContext.create(allocator);
    defer ctx.deinit(allocator);

    try std.testing.expectEqual(.Pending, ctx.status);
    try std.testing.expect(ctx.diagnostics.items.len == 0);
    try std.testing.expect(ctx.statusChanges.items.len == 0);
}

/// ShellTask represents a task that executes a shell command with arguments.
pub const ShellTask = struct {
    command: []const u8,
    args: []const []const u8,
    ctx: *TaskContext,

    /// Creates a new ShellTask with the given command and arguments.
    pub fn create(allocator: std.mem.Allocator, command: []const u8, arguments: []const []const u8) std.mem.Allocator.Error!ShellTask {
        const ctx = try allocator.create(TaskContext);
        ctx.* = try TaskContext.create(allocator);

        const newArgs = try allocator.alloc([]const u8, arguments.len);
        for (arguments, 0..) |arg, i| {
            newArgs[i] = try allocator.dupe(u8, arg);
        }

        return ShellTask{
            .command = try allocator.dupe(u8, command),
            .args = newArgs,
            .ctx = ctx,
        };
    }

    /// Executes the shell command with arguments, updating the task context accordingly.
    pub fn exec(self: *ShellTask, allocator: std.mem.Allocator) std.mem.Allocator.Error!TaskStatus {
        var argv = try std.ArrayList([]const u8).initCapacity(allocator, 1 + self.args.len);
        defer argv.deinit(allocator);

        argv.append(allocator, self.command) catch {
            try addDiag(self.ctx, allocator, "Failed to append command to argument list");
            return try self.ctx.changeStatus(allocator, .Failed);
        };
        for (self.args) |arg| {
            try argv.append(allocator, arg);
        }

        const argvSlice = try argv.toOwnedSlice(allocator);
        defer allocator.free(argvSlice);

        var child = std.process.Child.init(argvSlice, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;

        child.spawn() catch |err| {
            try addDiag(self.ctx, allocator, "Failed to spawn command");
            try addErrDiag(self.ctx, allocator, err);
            return try self.ctx.changeStatus(allocator, .Failed);
        };

        if (child.stdout) |s| {
            if (!builtin.is_test) {
                var readerBuf: [4096]u8 = undefined;
                var reader = s.reader(readerBuf[0..]);

                var outBuf: [4096]u8 = undefined;
                var stdout = std.fs.File.stdout().writer(outBuf[0..]);

                _ = std.Io.Writer.write(&stdout.interface, "\x1b[" ++ comptime logging.ColorCode.Cyan.toString() ++ "m") catch |err| {
                    try addDiag(self.ctx, allocator, logging.red("Error writing color code to stdout"));
                    try addErrDiag(self.ctx, allocator, err);
                    return try self.ctx.changeStatus(allocator, .Failed);
                };

                _ = std.Io.Reader.streamRemaining(&reader.interface, &stdout.interface) catch |err| {
                    try addDiag(self.ctx, allocator, logging.red("Error reading command stdout"));
                    try addErrDiag(self.ctx, allocator, err);
                    return try self.ctx.changeStatus(allocator, .Failed);
                };

                _ = std.Io.Writer.write(&stdout.interface, "\x1b[" ++ comptime logging.ColorCode.Reset.toString() ++ "m") catch |err| {
                    try addDiag(self.ctx, allocator, logging.red("Error writing reset color code to stdout"));
                    try addErrDiag(self.ctx, allocator, err);
                    return try self.ctx.changeStatus(allocator, .Failed);
                };

                std.Io.Writer.flush(&stdout.interface) catch |err| {
                    try addDiag(self.ctx, allocator, logging.red("Error flushing stdout"));
                    try addErrDiag(self.ctx, allocator, err);
                    return try self.ctx.changeStatus(allocator, .Failed);
                };
            }
        }

        const result = child.wait() catch |err| {
            try addDiag(self.ctx, allocator, logging.red("Failed to wait for command to finish"));
            try addErrDiag(self.ctx, allocator, err);
            return try self.ctx.changeStatus(allocator, .Failed);
        };

        switch (result) {
            .Unknown,
            => {
                try addDiag(self.ctx, allocator, logging.red("Command terminated abnormally"));
                return try self.ctx.changeStatus(allocator, .Failed);
            },
            .Signal => {
                try addDiag(self.ctx, allocator, logging.red("Command was terminated by signal"));
                return try self.ctx.changeStatus(allocator, .Failed);
            },
            .Stopped => {
                try addDiag(self.ctx, allocator, logging.red("Command was stopped"));
                return try self.ctx.changeStatus(allocator, .Failed);
            },
            .Exited => |code| {
                if (code != 0) {
                    const msg = try std.fmt.allocPrint(allocator, logging.red("Command exited with non-zero status: {}"), .{code});
                    try addDiag(self.ctx, allocator, msg);
                    allocator.free(msg);
                    return try self.ctx.changeStatus(allocator, .Failed);
                }
                return try self.ctx.changeStatus(allocator, .Completed);
            },
        }
    }

    /// Deinitializes the ShellTask, freeing all associated resources.
    pub fn deinit(self: *ShellTask, allocator: std.mem.Allocator) void {
        self.ctx.deinit(allocator);
        allocator.destroy(self.ctx);
        if (self.command.len > 0) {
            allocator.free(self.command);
            self.command = &[_]u8{};
        }
        if (self.args.len > 0) {
            for (self.args) |arg| {
                allocator.free(arg);
            }
            allocator.free(self.args);
            self.args = &[_][]const u8{};
        }
    }
};

test "ShellTask - exec with invalid command fails" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.debug.print("Leaked memory in test allocator\n", .{});
    };
    const allocator = gpa.allocator();

    var arg = [_][]const u8{ "arg1", "arg2" };
    var shellTask = try ShellTask.create(allocator, "/nonexistent/command", arg[0..]);
    defer shellTask.deinit(allocator);

    const status = try shellTask.exec(allocator);
    try std.testing.expectEqual(TaskStatus.Failed, status);
    try std.testing.expectEqual(TaskStatus.Failed, shellTask.ctx.status);
    try std.testing.expect(shellTask.ctx.diagnostics.items.len > 1);
    try std.testing.expectEqualStrings(logging.red("Error: FileNotFound"), shellTask.ctx.diagnostics.items[1].message);
}

test "ShellTask - exec with valid command succeeds" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.debug.print("Leaked memory in test allocator\n", .{});
    };
    const allocator = gpa.allocator();

    var arg = [_][]const u8{ "-c", "echo Hello, World!" };
    var shellTask = try ShellTask.create(allocator, "/bin/sh", arg[0..]);
    defer shellTask.deinit(allocator);

    const status = try shellTask.exec(allocator);
    try std.testing.expectEqual(TaskStatus.Completed, status);
    try std.testing.expectEqual(TaskStatus.Completed, shellTask.ctx.status);
}

test "ShellTask - exec with failed alloc propagates error" {
    var gpa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 7 });
    const allocator = gpa.allocator();
    var arg = [_][]const u8{ "arg1", "arg2" };
    var shellTask = try ShellTask.create(allocator, "/bin/echo", arg[0..]);
    defer shellTask.deinit(allocator);

    const execResult = shellTask.exec(allocator);
    try std.testing.expectError(std.mem.Allocator.Error.OutOfMemory, execResult);
}

test "ShellTask - create successfully creates a ShellTask" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.debug.print("Leaked memory in test allocator\n", .{});
    };
    const allocator = gpa.allocator();

    var arg = [_][]const u8{ "arg1", "arg2" };
    var shellTask = try ShellTask.create(allocator, "/bin/echo", arg[0..]);
    defer shellTask.deinit(allocator);

    try std.testing.expectEqualStrings(shellTask.command, "/bin/echo");
    try std.testing.expect(shellTask.args.len == 2);
    try std.testing.expectEqualStrings(shellTask.args[0], "arg1");
    try std.testing.expectEqualStrings(shellTask.args[1], "arg2");
    try std.testing.expectEqual(TaskStatus.Pending, shellTask.ctx.status);
}

/// MockTask is a simple task used for testing that returns a predefined status.
pub const MockTask = struct {
    status: TaskStatus,

    pub fn create(initialStatus: TaskStatus) MockTask {
        return MockTask{
            .status = initialStatus,
        };
    }
};

pub const TaskType = enum {
    Shell,
    Mock,
};

/// AnyTask is a union of all possible task implementations.
pub const AnyTask = union(TaskType) {
    Shell: ShellTask,
    Mock: MockTask,
};

/// Task represents a generic task with a name, options, and implementation.
/// Use the `deinit` method to free resources and `execute` to run the task.
/// Use the `create` function to create a new Task.
pub const Task = struct {
    name: []const u8,
    options: TaskOptions,
    impl: AnyTask,

    /// Creates a new Task with the given name, options, and implementation.
    pub fn create(allocator: std.mem.Allocator, name: []const u8, options: TaskOptions, impl: AnyTask) std.mem.Allocator.Error!Task {
        return Task{
            .name = try allocator.dupe(u8, name),
            .options = options,
            .impl = impl,
        };
    }

    /// Deinitializes the Task, freeing all associated resources.
    pub fn deinit(self: *const Task, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        switch (self.impl) {
            .Shell => |shellTask| {
                var task = shellTask;
                task.deinit(allocator);
            },
            .Mock => |_| {},
        }
    }

    fn executeSingle(self: *Task, allocator: std.mem.Allocator) std.mem.Allocator.Error!TaskStatus {
        switch (self.impl) {
            .Shell => |shellTask| {
                var task = shellTask;
                return task.exec(allocator);
            },
            .Mock => |mockTask| {
                var task = mockTask;
                return task.status;
            },
        }
    }

    /// Executes the task based on its implementation and returns the resulting TaskStatus.
    pub fn execute(self: *Task, allocator: std.mem.Allocator) std.mem.Allocator.Error!TaskStatus {
        const res = try self.executeSingle(allocator);
        if (res == TaskStatus.Failed and self.options.retryCount > 0) {
            var attempt: u8 = 0;
            while (attempt < self.options.retryCount) : (attempt += 1) {
                const initialDelayFloat: f32 = @floatFromInt(self.options.retryDelaySeconds);
                const delayFloat = initialDelayFloat * std.math.pow(f32, self.options.retryMultiplier, @floatFromInt(attempt));
                const delay: u64 = @intFromFloat(delayFloat);
                std.Thread.sleep(delay);
                const retryRes = try self.executeSingle(allocator);
                if (retryRes != TaskStatus.Failed) {
                    return retryRes;
                }
            }
        }
        return res;
    }
};

test "Task - execute MockTask returns predefined status" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.debug.print("Leaked memory in test allocator\n", .{});
    };
    const allocator = gpa.allocator();

    var mockTask = try Task.create(allocator, "Mock Success Task", TaskOptions{}, AnyTask{ .Mock = MockTask.create(.Completed) });
    defer mockTask.deinit(allocator);

    const status = try mockTask.execute(allocator);
    try std.testing.expectEqual(TaskStatus.Completed, status);
}

test "Task - retry logic works for ShellTask" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.debug.print("Leaked memory in test allocator\n", .{});
    };
    const allocator = gpa.allocator();

    var arg = [_][]const u8{ "arg1", "arg2" };
    var shellTask = try Task.create(allocator, "Shell Task with Retries", TaskOptions{
        .retryCount = 2,
        .retryDelaySeconds = 1,
        .retryMultiplier = 2.0,
        .timeoutSeconds = 10,
    }, AnyTask{ .Shell = try ShellTask.create(allocator, "/nonexistent/command", arg[0..]) });
    defer shellTask.deinit(allocator);

    const status = try shellTask.execute(allocator);
    try std.testing.expectEqual(TaskStatus.Failed, status);
    try std.testing.expectEqual(TaskStatus.Failed, switch (shellTask.impl) {
        .Shell => |s| s.ctx.status,
        else => unreachable,
    });
}

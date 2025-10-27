const task = @import("./task.zig");
const std = @import("std");
const logging = @import("./logging.zig");

pub const WorkflowError = error{
    /// A step specified in the entry point or in a transition was not found.
    StepNotFound,
    /// An error occurred inside a task's execution.
    TaskExecutionFailed,
    /// The workflow likely has a cycle in its steps, causing too many iterations.
    MaxIterationsExceeded,
    // A problem occurred while spawning or managing threads.
    ThreadError,
    // A cycle was detected in the workflow transitions.
    CycleDetected,
};

/// Defines a step in the workflow, including its name, associated task,
/// and optional transitions for completion and error handling.
pub const WorkflowStep = struct {
    name: []const u8,
    task: *task.Task,
    /// Transition to another step if an error occurs while executing the task.
    /// Does not transition if the task fails without error, or if errors unrelated
    /// to task execution occur, such as memory allocation failures.
    onError: ?[]const u8,
    /// This workflow will not start until all steps in dependsOn have completed.
    /// Workflows whose dependencies have completed may run in parallel.
    dependsOn: ?[]const []const u8,

    /// Creates a new WorkflowStep with the given parameters.
    pub fn create(allocator: std.mem.Allocator, name: []const u8, passedTask: task.Task, onError: ?[]const u8, dependsOn: ?[]const []const u8) std.mem.Allocator.Error!WorkflowStep {
        const taskRef = try allocator.create(task.Task);
        taskRef.* = passedTask;

        return WorkflowStep{
            .name = try allocator.dupe(u8, name),
            .task = taskRef,
            .onError = if (onError) |msg| try allocator.dupe(u8, msg) else null,
            .dependsOn = if (dependsOn) |deps| dependsOn: {
                const depsCopy = try allocator.alloc([]const u8, deps.len);
                for (deps, 0..) |_, index| {
                    depsCopy[index] = try allocator.dupe(u8, deps[index]);
                }
                break :dependsOn depsCopy;
            } else null,
        };
    }

    /// Deinitializes the WorkflowStep, freeing associated resources.
    pub fn deinit(self: *WorkflowStep, allocator: std.mem.Allocator) void {
        allocator.free(self.name);

        if (self.dependsOn) |deps| {
            for (deps) |dep| {
                allocator.free(dep);
            }
            allocator.free(deps);
        }

        if (self.onError) |msg| {
            allocator.free(msg);
        }
        self.task.deinit(allocator);
        allocator.destroy(self.task);
    }
};

/// Represents a workflow consisting of multiple steps and a queue for managing
/// the execution order.
/// Each step can define transitions to other steps based on task completion or errors.
/// The workflow starts execution from a specified entry point.
/// Example usage:
/// ```
/// const steps = [_]WorkflowStep{ ... };
/// var workflow = try Workflow.create(&steps, "entryStep", allocator);
/// defer workflow.deinit(allocator); // Remember to deinitialize
/// try workflow.execute(allocator);
/// ```
pub const Workflow = struct {
    steps: []*WorkflowStep,
    queue: std.ArrayList([]const u8),
    entryPoint: []const u8,
    /// Internal
    backing: []WorkflowStep,
    concurrency: usize = 4,

    fn find(self: *Workflow, name: []const u8) ?*const WorkflowStep {
        for (self.steps, 0..) |step, index| {
            if (std.mem.eql(u8, step.name, name)) {
                return self.steps[index];
            }
        }
        return null;
    }

    fn executeStep(self: *Workflow, allocator: std.mem.Allocator, stepName: []const u8) (WorkflowError || std.mem.Allocator.Error)!void {
        std.log.info(logging.grey("Executing step: {s}"), .{stepName});

        const step = self.find(stepName) orelse return WorkflowError.StepNotFound;

        const result = try step.task.execute(allocator);
        switch (result) {
            .Completed => {},
            .Failed => {
                if (step.onError) |msg| {
                    try self.queue.append(allocator, msg);
                } else {
                    std.log.err(logging.red("Task {s} failed with status {s} without onError transition."), .{ step.name, result.toString() });
                    switch (step.task.impl) {
                        .Shell => |shellTask| {
                            for (shellTask.ctx.diagnostics.items) |diag| {
                                std.log.err(logging.red("Shell Task Diagnostic: {s}"), .{diag.message});
                            }
                        },
                        else => {},
                    }
                    return WorkflowError.TaskExecutionFailed;
                }
            },
            else => {
                return WorkflowError.TaskExecutionFailed;
            },
        }
    }

    fn populateQueue(self: *Workflow, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        outer: for (self.steps) |step| {
            for (self.queue.items) |queuedName| {
                if (std.mem.eql(u8, queuedName, step.name)) {
                    continue :outer;
                }
            }

            switch (step.task.impl) {
                .Mock => |mockTask| {
                    if (mockTask.status == .Completed or mockTask.status == .Failed) {
                        continue :outer;
                    }
                },
                .Shell => |shellTask| {
                    if (shellTask.ctx.status == .Completed or shellTask.ctx.status == .Failed) {
                        continue :outer;
                    }
                },
            }

            if (step.dependsOn) |deps| {
                var allDepsMet = false;
                for (deps) |depName| {
                    for (self.steps) |other| {
                        if (!std.mem.eql(u8, other.name, depName)) continue;
                        if (std.mem.eql(u8, other.name, step.name)) continue;
                        var isDone = false;
                        switch (other.task.impl) {
                            .Mock => |mockTask| {
                                if (mockTask.status == .Completed) {
                                    isDone = true;
                                }
                            },
                            .Shell => |shellTask| {
                                if (shellTask.ctx.status == .Completed) {
                                    isDone = true;
                                }
                            },
                        }

                        if (isDone) {
                            allDepsMet = true;
                            break;
                        }
                    }
                }

                if (!allDepsMet) continue;

                try self.queue.append(allocator, step.name);
            } else {
                try self.queue.append(allocator, step.name);
            }
        }
    }

    fn threadWorker(self: *Workflow, allocator: std.mem.Allocator, wg: *std.Thread.WaitGroup, stepName: []const u8) void {
        self.executeStep(allocator, stepName) catch {}; // handled by thread creator using task status
        wg.finish();
    }

    /// Executes the workflow starting from the entry point, processing each step
    /// in the queue until completion or until the maximum number of iterations is reached.
    pub fn execute(self: *Workflow, allocator: std.mem.Allocator) (WorkflowError || std.mem.Allocator.Error)!void {
        var threadPool: std.Thread.Pool = undefined;
        threadPool.init(.{ .allocator = allocator, .n_jobs = self.concurrency }) catch |err| {
            std.log.err(logging.red("Failed to initialize thread pool: {s}"), .{@errorName(err)});
            return WorkflowError.ThreadError;
        };
        defer threadPool.deinit();

        var waitGroup: std.Thread.WaitGroup = .{};

        try self.queue.append(allocator, self.entryPoint);

        var iterations: usize = 0;
        const maxIterations: usize = 1000;
        while (iterations < maxIterations) : (iterations += 1) {
            _ = try self.populateQueue(allocator);
            if (self.queue.items.len == 0) break;
            var startedSteps = try std.ArrayList([]const u8).initCapacity(allocator, self.queue.items.len);

            for (0..@min(self.queue.items.len, self.concurrency)) |_| {
                const currentStepName = self.queue.orderedRemove(0);
                waitGroup.start();
                threadPool.spawn(threadWorker, .{ self, allocator, &waitGroup, currentStepName }) catch |err| {
                    std.log.err(logging.red("Failed to spawn thread for step {s}: {s}"), .{ currentStepName, @errorName(err) });
                    return WorkflowError.ThreadError;
                };
                startedSteps.append(allocator, currentStepName) catch |err| {
                    std.log.err(logging.red("Failed to track started step {s}: {s}"), .{ currentStepName, @errorName(err) });
                    return WorkflowError.ThreadError;
                };
            }
            waitGroup.wait();
            for (startedSteps.items) |stepName| {
                const step = self.find(stepName) orelse return WorkflowError.StepNotFound;
                switch (step.task.impl) {
                    .Mock => |mockTask| {
                        if (mockTask.status == .Failed and step.onError == null) {
                            return WorkflowError.TaskExecutionFailed;
                        }
                    },
                    .Shell => |shellTask| {
                        if (shellTask.ctx.status == .Failed and step.onError == null) {
                            return WorkflowError.TaskExecutionFailed;
                        }
                    },
                }
            }
            waitGroup.reset();
            startedSteps.deinit(allocator);
        }

        if (iterations >= maxIterations) {
            return WorkflowError.MaxIterationsExceeded;
        }
    }

    fn detectCycles(allocator: std.mem.Allocator, steps: []WorkflowStep) WorkflowError!void {
        // only onError transitions can create cycles
        var visited = std.StringHashMap(bool).init(allocator);
        defer visited.deinit();

        const maxIterations: usize = 1000;
        var iterations: usize = 0;
        while (iterations < maxIterations) : (iterations += 1) {
            var progress = false;
            for (steps) |step| {
                if (visited.get(step.name) orelse false) continue;
                if (step.onError) |nextStepName| {
                    if (std.mem.eql(u8, nextStepName, step.name)) {
                        return WorkflowError.CycleDetected;
                    }
                    if (visited.get(nextStepName) orelse false) {
                        visited.put(step.name, true) catch {};
                        progress = true;
                    }
                } else {
                    visited.put(step.name, true) catch {};
                    progress = true;
                }
            }
            if (!progress) break;
        }
        if (iterations >= maxIterations) {
            return WorkflowError.MaxIterationsExceeded;
        }
    }

    /// Initializes a new Workflow with the given steps and entry point.
    pub fn create(steps: []WorkflowStep, entryPoint: []const u8, allocator: std.mem.Allocator, concurrency: ?usize) (std.mem.Allocator.Error || WorkflowError)!Workflow {
        const queue = try std.ArrayList([]const u8).initCapacity(allocator, steps.len);
        const stepCopy = try allocator.dupe(WorkflowStep, steps);
        const stepPtrArray = try allocator.alloc(*WorkflowStep, steps.len);
        const entryPointDupe = try allocator.dupe(u8, entryPoint);
        for (stepCopy, 0..) |_, index| {
            stepPtrArray[index] = &stepCopy[index];
        }

        var workflow = Workflow{
            .steps = stepPtrArray,
            .backing = stepCopy,
            .queue = queue,
            .entryPoint = entryPointDupe,
            .concurrency = concurrency orelse 4,
        };
        errdefer workflow.deinit(allocator);

        try detectCycles(allocator, steps);

        return workflow;
    }

    /// Deinitializes the workflow, freeing associated resources.
    pub fn deinit(self: *Workflow, allocator: std.mem.Allocator) void {
        for (self.steps) |step| {
            step.deinit(allocator);
        }
        allocator.free(self.steps);
        allocator.free(self.entryPoint);
        allocator.free(self.backing);
        self.queue.deinit(allocator);
    }
};

test "Workflow execution with onError transition" {
    const allocator = std.testing.allocator;
    const task1 = try task.Task.create(allocator, "MockTask1", .{}, task.AnyTask{ .Mock = task.MockTask.create(.Failed) });
    const step1 = try WorkflowStep.create(allocator, "step1", task1, "step3", null);

    const task2 = try task.Task.create(allocator, "MockTask2", .{}, task.AnyTask{ .Mock = task.MockTask.create(.Completed) });
    const step2 = try WorkflowStep.create(allocator, "step2", task2, null, (&[_][]const u8{"step1"})[0..]);

    const task3 = try task.Task.create(allocator, "MockTask3", .{}, task.AnyTask{ .Mock = task.MockTask.create(.Completed) });
    const step3 = try WorkflowStep.create(allocator, "step3", task3, null, null);

    var steps = [_]WorkflowStep{ step1, step2, step3 };
    var workflow = try Workflow.create(&steps, "step1", allocator, 1);
    defer workflow.deinit(allocator);

    try workflow.executeStep(allocator, "step1");
    try std.testing.expectEqual(1, workflow.queue.items.len);
    try std.testing.expectEqualStrings("step3", workflow.queue.items[0]);
}

test "Workflow full execution" {
    const allocator = std.testing.allocator;
    const task1 = try task.Task.create(allocator, "MockTask1", .{}, task.AnyTask{ .Mock = task.MockTask.create(.Completed) });
    const step1 = try WorkflowStep.create(allocator, "step1", task1, null, null);

    const task2 = try task.Task.create(allocator, "MockTask2", .{}, task.AnyTask{ .Mock = task.MockTask.create(.Completed) });
    const step2 = try WorkflowStep.create(allocator, "step2", task2, null, (&[_][]const u8{"step1"})[0..]);

    var steps = [_]WorkflowStep{ step1, step2 };
    var workflow = try Workflow.create(&steps, "step1", allocator, 1);
    defer workflow.deinit(allocator);

    try workflow.execute(allocator);
    try std.testing.expectEqual(0, workflow.queue.items.len);
}

test "should break infinite loop" {
    const allocator = std.testing.allocator;
    const task1 = try task.Task.create(allocator, "MockTask1", .{}, task.AnyTask{ .Mock = task.MockTask.create(.Failed) });
    const step1 = try WorkflowStep.create(allocator, "step1", task1, "step1", null);

    var steps = [_]WorkflowStep{step1};
    const err = Workflow.create(&steps, "step1", allocator, null);
    try std.testing.expectError(WorkflowError.CycleDetected, err);
}

test "runs working shell workflow" {
    const allocator = std.testing.allocator;

    const helloShellTask = try task.ShellTask.create(allocator, "echo", &[_][]const u8{"hello"});

    const task1 = try task.Task.create(allocator, "EchoHello", .{}, task.AnyTask{ .Shell = helloShellTask });
    const step1 = try WorkflowStep.create(allocator, "step1", task1, null, null);

    const worldShellTask = try task.ShellTask.create(allocator, "echo", (&[_][]const u8{"world"})[0..]);
    const task2 = try task.Task.create(allocator, "EchoWorld", .{}, task.AnyTask{ .Shell = worldShellTask });
    const step2 = try WorkflowStep.create(allocator, "step2", task2, null, (&[_][]const u8{"step1"})[0..]);

    var steps = [_]WorkflowStep{ step1, step2 };
    var workflow = try Workflow.create(&steps, "step1", allocator, 1);
    defer workflow.deinit(allocator);

    try workflow.execute(allocator);
}

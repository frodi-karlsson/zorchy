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
};

/// Defines a step in the workflow, including its name, associated task,
/// and optional transitions for completion and error handling.
pub const WorkflowStep = struct {
    name: []const u8,
    task: *task.Task,
    onComplete: ?[]const u8,
    /// Transition to another step if an error occurs while executing the task.
    /// Does not transition if the task fails without error, or if errors unrelated
    /// to task execution occur, such as memory allocation failures.
    onError: ?[]const u8,

    /// Creates a new WorkflowStep with the given parameters.
    pub fn create(allocator: std.mem.Allocator, name: []const u8, passedTask: task.Task, onComplete: ?[]const u8, onError: ?[]const u8) std.mem.Allocator.Error!WorkflowStep {
        const taskRef = try allocator.create(task.Task);
        taskRef.* = passedTask;

        return WorkflowStep{
            .name = try allocator.dupe(u8, name),
            .task = taskRef,
            .onComplete = if (onComplete) |msg| try allocator.dupe(u8, msg) else null,
            .onError = if (onError) |msg| try allocator.dupe(u8, msg) else null,
        };
    }

    /// Deinitializes the WorkflowStep, freeing associated resources.
    pub fn deinit(self: *WorkflowStep, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.onComplete) |msg| {
            allocator.free(msg);
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
    /// do not use me
    backing: []WorkflowStep,

    fn find(self: *Workflow, name: []const u8) ?*const WorkflowStep {
        for (self.steps, 0..) |step, index| {
            if (std.mem.eql(u8, step.name, name)) {
                return self.steps[index];
            }
        }
        return null;
    }

    fn executeStep(self: *Workflow, allocator: std.mem.Allocator, stepName: []const u8) (WorkflowError || std.mem.Allocator.Error)!void {
        const step = self.find(stepName) orelse return WorkflowError.StepNotFound;
        const result = try step.task.execute(allocator);
        switch (result) {
            .Completed => {
                if (step.onComplete) |msg| {
                    const dupe = try allocator.dupe(u8, msg);
                    try self.queue.append(allocator, dupe);
                }
            },
            .Failed => {
                if (step.onError) |msg| {
                    const dupe = try allocator.dupe(u8, msg);
                    try self.queue.append(allocator, dupe);
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

    /// Executes the workflow starting from the entry point, processing each step
    /// in the queue until completion or until the maximum number of iterations is reached.
    pub fn execute(self: *Workflow, allocator: std.mem.Allocator) (WorkflowError || std.mem.Allocator.Error)!void {
        const entryPointDupe = try allocator.dupe(u8, self.entryPoint);
        try self.queue.append(allocator, entryPointDupe);
        var iterations: usize = 0;
        const maxIterations: usize = 1000;
        while (iterations < maxIterations) : (iterations += 1) {
            if (self.queue.items.len == 0) break;
            const currentStepName = self.queue.orderedRemove(0);
            std.log.info(logging.grey("Executing step: {s}"), .{currentStepName});

            try self.executeStep(allocator, currentStepName);
            allocator.free(currentStepName);
        }

        if (iterations >= maxIterations) {
            return WorkflowError.MaxIterationsExceeded;
        }
    }

    /// Initializes a new Workflow with the given steps and entry point.
    pub fn create(steps: []WorkflowStep, entryPoint: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!Workflow {
        const queue = try std.ArrayList([]const u8).initCapacity(allocator, steps.len);
        const stepCopy = try allocator.dupe(WorkflowStep, steps);
        const stepPtrArray = try allocator.alloc(*WorkflowStep, steps.len);
        for (stepCopy, 0..) |_, index| {
            stepPtrArray[index] = &stepCopy[index];
        }

        return Workflow{
            .steps = stepPtrArray,
            .backing = stepCopy,
            .queue = queue,
            .entryPoint = entryPoint,
        };
    }

    /// Deinitializes the workflow, freeing associated resources.
    pub fn deinit(self: *Workflow, allocator: std.mem.Allocator) void {
        for (self.steps) |step| {
            step.deinit(allocator);
        }
        allocator.free(self.steps);
        allocator.free(self.backing);
        for (self.queue.items) |item| {
            allocator.free(item);
        }
        self.queue.deinit(allocator);
    }
};

test "Workflow execution with onComplete transition" {
    const allocator = std.testing.allocator;
    const task1 = try task.Task.create(allocator, "MockTask1", .{}, task.AnyTask{ .Mock = task.MockTask.create(.Completed) });
    const step1 = try WorkflowStep.create(allocator, "step1", task1, "step2", null);

    const task2 = try task.Task.create(allocator, "MockTask2", .{}, task.AnyTask{ .Mock = task.MockTask.create(.Completed) });
    const step2 = try WorkflowStep.create(allocator, "step2", task2, null, null);

    var steps = [_]WorkflowStep{ step1, step2 };
    var workflow = try Workflow.create(&steps, "step1", allocator);
    defer workflow.deinit(allocator);

    try workflow.executeStep(allocator, "step1");
    try std.testing.expectEqual(1, workflow.queue.items.len);
    try std.testing.expectEqualStrings("step2", workflow.queue.items[0]);
}

test "Workflow execution with onError transition" {
    const allocator = std.testing.allocator;
    const task1 = try task.Task.create(allocator, "MockTask1", .{}, task.AnyTask{ .Mock = task.MockTask.create(.Failed) });
    const step1 = try WorkflowStep.create(allocator, "step1", task1, "step2", "step3");

    const task2 = try task.Task.create(allocator, "MockTask2", .{}, task.AnyTask{ .Mock = task.MockTask.create(.Completed) });
    const step2 = try WorkflowStep.create(allocator, "step2", task2, null, null);

    const task3 = try task.Task.create(allocator, "MockTask3", .{}, task.AnyTask{ .Mock = task.MockTask.create(.Completed) });
    const step3 = try WorkflowStep.create(allocator, "step3", task3, null, null);

    var steps = [_]WorkflowStep{ step1, step2, step3 };
    var workflow = try Workflow.create(&steps, "step1", allocator);
    defer workflow.deinit(allocator);

    try workflow.executeStep(allocator, "step1");
    try std.testing.expectEqual(1, workflow.queue.items.len);
    try std.testing.expectEqualStrings("step3", workflow.queue.items[0]);
}

test "Workflow full execution" {
    const allocator = std.testing.allocator;
    const task1 = try task.Task.create(allocator, "MockTask1", .{}, task.AnyTask{ .Mock = task.MockTask.create(.Completed) });
    const step1 = try WorkflowStep.create(allocator, "step1", task1, "step2", null);

    const task2 = try task.Task.create(allocator, "MockTask2", .{}, task.AnyTask{ .Mock = task.MockTask.create(.Completed) });
    const step2 = try WorkflowStep.create(allocator, "step2", task2, null, null);

    var steps = [_]WorkflowStep{ step1, step2 };
    var workflow = try Workflow.create(&steps, "step1", allocator);
    defer workflow.deinit(allocator);

    try workflow.execute(allocator);
    try std.testing.expectEqual(0, workflow.queue.items.len);
}

test "should break infinite loop" {
    const allocator = std.testing.allocator;
    const task1 = try task.Task.create(allocator, "MockTask1", .{}, task.AnyTask{ .Mock = task.MockTask.create(.Completed) });
    const step1 = try WorkflowStep.create(allocator, "step1", task1, "step1", null);

    var steps = [_]WorkflowStep{step1};
    var workflow = try Workflow.create(&steps, "step1", allocator);
    defer workflow.deinit(allocator);

    const err = workflow.execute(allocator);
    try std.testing.expectEqual(1, workflow.queue.items.len);
    try std.testing.expectEqual(WorkflowError.MaxIterationsExceeded, err);
}

test "runs working shell workflow" {
    const allocator = std.testing.allocator;

    const helloShellTask = try task.ShellTask.create(allocator, "echo", &[_][]const u8{"hello"});

    const task1 = try task.Task.create(allocator, "EchoHello", .{}, task.AnyTask{ .Shell = helloShellTask });
    const step1 = try WorkflowStep.create(allocator, "step1", task1, "step2", null);

    const worldShellTask = try task.ShellTask.create(allocator, "echo", &[_][]const u8{"world"});
    const task2 = try task.Task.create(allocator, "EchoWorld", .{}, task.AnyTask{ .Shell = worldShellTask });
    const step2 = try WorkflowStep.create(allocator, "step2", task2, null, null);

    var steps = [_]WorkflowStep{ step1, step2 };
    var workflow = try Workflow.create(&steps, "step1", allocator);
    defer workflow.deinit(allocator);

    try workflow.execute(allocator);
}

# zorchy

zorchy is a small workflow runner written in Zig.
It executes task graphs defined in JSON, allowing error handling through `onError` transitions.
There is also concurrency and dependency support through the `concurrency` and `dependsOn` fields.

It is a learning project for me in zig and nothing to take too seriously.

## Status

Work in progress.
Currently supports sequential workflows and basic shell tasks.
Next steps include:
- Parallel task execution
- Additional task types (HTTP, renaming Mock, more?)

## Example

More examples exist / coming soon in the `./integration` folder.

```json
{
  "$schema": "../schema.json",
  "entryPoint": "make dir",
  "workflows": [
    {
      "name": "make dir",
      "task": {
        "Shell": {
          "command": "mkdir",
          "args": ["-p", "./integration/out/1"]
        }
      }
    },
    {
      "name": "make file",
      "task": {
        "Shell": {
          "command": "touch",
          "args": ["./integration/out/1/output.txt"]
        }
      },
      "dependsOn": ["make dir"]
    },
    {
      "name": "populate file",
      "task": {
        "Shell": {
          "command": "sh",
          "args": [
            "-c",
            "echo \"Hello, World!\" > ./integration/out/1/output.txt"
          ]
        }
      },
      "dependsOn": ["make file"]
    },
  ]
}
```

This example defines a chain of shell tasks:
1. Create a file
2. Populate it
3. Verify its contents
4. Read the first line
5. Trigger a failure
6. Finish gracefully

## Building

zorchy uses the Zig build system.
You can build and install it with:

zig build install

To run directly:

zig build run -- path/to/workflow.json

The build script defines a few steps:

- `zig build` — build and install
- `zig build run -- <args>` — run the CLI
- `zig build test` — run all tests
- `zig build integration` — run integration workflows from `./integration`

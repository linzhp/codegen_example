# How to define a Bazel rule to generate Go code
## Introduction
At Uber, we use Bazel, an open source build system from Google, to build our [Go monorepo](https://eng.uber.com/go-monorepo-bazel/), which heavily uses generated code. A simple approach to manage generated code is to check them into the source repository and build them in the same way as manually written code. However, this approach would increase the size of the source repository, leading to performance issues. In addition, the generated code can often get outdated, leading to unexpected build failures. To avoid these issues, we decided to generate code as part of Bazel builds. With build cache, Bazel will automatically decide whether the generated code needs to be updated. To tell Bazel how to generate code, we need to define the code generation process as [rules](https://docs.bazel.build/versions/master/skylark/rules.html).

The open source community has developed Bazel rules for some commonly used code generators. Most notable ones are [go_proto_library](https://github.com/bazelbuild/rules_go/blob/master/proto/core.rst#go_proto_library) for protoc, [gomock](https://github.com/jmhodges/bazel_gomock) for mockgen. However, there are cases when people want to use their own code generators. This article is a step-by-step tutorial on how to write a Bazel rule to generate and build code with a custom code generator.

This article assumes you are in a repository with Bazel Go rules and Gazelle properly set up. If not, please follow the [Setup](https://github.com/bazelbuild/bazel-gazelle#setup) section of Gazelle to do so.

## Toy Code Generator
Let’s first create a toy code generator, which reads a configuration file to fill a template, then write the result into a Go file. The code generator looks like this:

```go
func main() {
  pkg := flag.String("package", "codegen", "the package name in the generated code file")
  tmplPath := flag.String("tmpl", "factory/templates/things.tmpl", "the template file")
  configPath := flag.String("config", "factory/config/base.json", "the configuration file")
  outPath := flag.String("out", "out.go", "the output file")
  flag.Parse()
  file, err := os.Open(*configPath)
  check(err)
  decoder := json.NewDecoder(file)
  var config Configuration
  if err = decoder.Decode(&config); err != nil {
    log.Fatal(err)
  }
  config.Package = *pkg

  rawBytes, err := ioutil.ReadFile(*tmplPath)
  check(err)
  tmpl, err := template.New("thing").Parse(string(rawBytes))
  check(err)
  out, err := os.Create(*outPath)
  check(err)
  err = tmpl.Execute(out, config)
  check(err)
}

type Configuration struct {
  Package  string
  Count    int
  Material string
}
```

The template file looks like this:

```go
// Generated code. DO NOT EDIT
package {{.Package}}

func String() string {
	return "{{.Count}} items are made of {{.Material}}"
}
```

The configuration file:

```json
{
  "Material": "wool",
  "Count": 17
}
```

Now if we run Gazelle with `bazel run //:gazelle`, a BUILD.bazel file will be generated for the code generator with a go_binary rule in it. Now we add a data parameter to the go_binary rule:

```python
data = glob([
    "config/*.json",
    "templates/*.tmpl",
]),
```

With this parameter, we are able to run the code generator (which is under a directory called `factory`) like this:

```bash
$ bazel run //factory:factory -- -out=/tmp/out.go -config factory/config/base.json -tmpl factory/templates/things.tmpl
```

If it succeeds, we can find /tmp/out.go is generated. As the output itself is a Go file, we want to also compile the Go file too. Of course, we can copy the Go file into some directory in the repository, and use Bazel to compile it. However, how do we make Bazel both generate the file and compile it with one single “bazel build” command? We need to define a Bazel rule on our own.

## Declaring a rule

Bazel has a go_library rule to compile Go files, so we don’t need to worry about compilation. However, for the toy code generator we just invented, we need to write a Bazel rule from scratch. A rule definition consists of at least two parts: a declaration and an implementation. We will start with a rule declaration in this section and cover the implementation in the next.

```python
load("@io_bazel_rules_go//go:def.bzl", "go_rule")

def _codegen_impl(ctx):
  # to be done in the next section
  pass

factory = go_rule(
    _codegen_impl,
    attrs = {
        "_template": attr.label(
            allow_single_file = True,
            default = "//factory/templates:things.tmpl",
        ),
        "config": attr.label(
            allow_single_file = True,
        ),
        "package": attr.string(
            doc = "the package name for the generated Go file",
        ),
        "_generator": attr.label(
            executable = True,
            cfg = "host",
            default = "//factory",
        ),
    },
)
```

In this code snippet, we declare a Bazel rule called `factory`. As part of the declaration, we provide it with an implementation function of the rule call `_codegen_impl`. Then we declare all build targets this rule depends on, such as executable targets and files. In this example, the only executable is the `//factory:factory` target we created in the last section. If the executable calls other tools such as gofmt programmatically after generating the Go file, gofmt has to be specified here too. Similarly, all the files `//factory:factory` needs to read during its execution have to be declared in the rule declaration, even if the file path is hard coded in the code instead of passed in as a command line argument to the code generator.

For some rule attributes that we don’t want users to customize, they can have their name starting with an underscore. In this example, we don’t want users to customize template and the code generator location, but they need to be declared as attributes because they are inputs to the rule, so we declare them as `_template` and `_generator`, and assign a default value to each of them.

More information about the attributes can be found in the official [Bazel document](https://docs.bazel.build/versions/master/skylark/rules.html#attributes).

## Rule implementation
Rule implementation is the actual code that calls the code generator, reads the input, and generates the Go file, according to the values of rule attributes users pass in.

```python
def _codegen_impl(ctx):
    out = ctx.actions.declare_file("out.go")
    args = ctx.actions.args()
    args.add("-config", ctx.file.config.path)
    args.add("-out", out.path)
    args.add("-package", ctx.attr.package)
    ctx.actions.run(
        inputs = [ctx.file._template, ctx.file.config],
        outputs = [out],
        executable = ctx.executable._generator,
        tools = [ctx.executable._generator],
        arguments = [args],
        mnemonic = "SmallFactory",
    )
    return [
        DefaultInfo(files = depset([out])),
    ]
```

In the code snippet above, we first declare that the rule is going to generate a file called `out.go`.
Then we construct the command line arguments to the code generator. Some of the values are from the rule attributes declared in the rule. Note that we do not pass the template, and instead let the code generator use its default template. The function `ctx.actions.run` is the one that executes the code generator. Although we do not pass the template in the command line arguments, we still have to specify it as one of the inputs to the action. The `executable` parameter specifies the main executable of the action. However, the main executable may programmatically call other executables. All of these executables have to be specified in the `tools` parameter.

Finally, the rule returns some [providers](https://docs.bazel.build/versions/master/skylark/rules.html#providers) that other rules may need. In our example, the only output is the generated Go file. Some other rules may also compile the Go file too, making the binary file the final output. If this is the case, it's better to return an extra provider called `OutputGroupInfo`, and put the generated Go file in an output group called `go_generated_srcs`, similar to [go_proto_library](https://github.com/bazelbuild/rules_go/blob/ac1b0e0544de55a1ef2cbd37b30503c9e860f795/proto/def.bzl#L127-L139):

```python
return [
    DefaultInfo(files = depset([ctx.outputs.out])),
    OutputGroupInfo(
        go_generated_srcs = [ctx.outputs.out],
    ),
]
```

So we can generate the Go code without other unnecessary steps by:

```bash
$ bazel build --output_groups=go_generated_srcs //some/code/gen:target
```

## Using the factory rule

Now we can use the newly created `factory` rule to generate code. After loading the rule, we pass a new configuration file, a package name for the generated code, and the output file name.

```python
load("//:rules/factory.bzl", "factory")

factory(
    name = "go_factory",
    config = "config/config.json",
    package = "main",
)
```

Assuming we save this rule in `stone/BUILD.bazel`, we can execute the rule using the following Bazel build command:

```bash
$ bazel build //stone:go_factory
INFO: Analyzed target //stone:go_factory (1 packages loaded, 2 targets configured).
INFO: Found 1 target...
Target //stone:go_factory up-to-date:
  bazel-bin/stone/stone.go
INFO: Elapsed time: 0.138s, Critical Path: 0.00s
INFO: 0 processes.
INFO: Build completed successfully, 1 total action
```

We can see that a Go file has been generated at `bazel-bin/stone/stone.go`:

```go
// Generated code. DO NOT EDIT
package main

func String() string {
  return "17 items are made of stone"
}
```

## Compiling the generated code

Now we can compile this generated code along with other regular Go files. Let’s first create a `print.go` file to call the generated function `String()`:

```go
package main

import "fmt"

func main() {
  fmt.Println(String())
}
```

After putting this new Go file along side with `stone/BUILD.bazel`, and run Gazelle (`bazel run //:gazelle`), a `go_library` and a `go_binary` rule will be generated. In order to compile the generated code, we need to add the code generation target to the `srcs` of `go_library`:

```python
go_library(
    name = "go_default_library",
    srcs = [
        "print.go",
        ":go_factory",  # keep
    ],
    importpath = "github.com/linzhp/codegen_example/stone",
    visibility = ["//visibility:public"],
)

go_binary(
    name = "stone",
    embed = [":go_default_library"],
    visibility = ["//visibility:public"],
)
```

Note that we also put a `# keep` directive besides the `:go_factory` target, so future run of Gazelle will preserve the manually added target. When we pass the `:go_factory` target into `srcs`, we are actually passing the files in the `DefaultInfo` provider returned by `_codegen_impl`.

Now we can build a binary from both Go files:

```bash
$ bazel build //stone:stone
INFO: Analyzed target //stone:stone (0 packages loaded, 4 targets configured).
INFO: Found 1 target...
Target //stone:stone up-to-date:
  bazel-bin/stone/darwin_amd64_stripped/stone
INFO: Elapsed time: 0.122s, Critical Path: 0.00s
INFO: 0 processes.
INFO: Build completed successfully, 1 total action
```

## All in one step
As we promised, we want to do the code generation, compilation with one Bazel command. We can actually go one step further and run the final binary. As we had run some build commands before, let’s run `bazel clean` command to remove all the artifacts generated by previous commands and make sure that both `bazel-bin/stone/stone.go` and `bazel-bin/stone/darwin_amd64_stripped/stone` are gone. Now we can do all the steps in a Bazel run command:

```bash
$ bazel run //stone
INFO: Analyzed target //stone:stone (29 packages loaded, 6670 targets configured).
INFO: Found 1 target...
Target //stone:stone up-to-date:
  bazel-bin/stone/darwin_amd64_stripped/stone
INFO: Elapsed time: 3.475s, Critical Path: 1.47s
INFO: 6 processes: 6 darwin-sandbox.
INFO: Build completed successfully, 12 total actions
INFO: Build completed successfully, 12 total actions
17 items are made of stone
```

This command first tries to build `//stone:stone`, and finds that its dependencies have not built yet. So it builds the dependencies first, which includes the code generation. After the binary is built, the command also executes the binary, which prints out the string from the generated code: "17 items are made of stone."

The full working example can be found at https://github.com/linzhp/codegen_example. Thanks for reading.

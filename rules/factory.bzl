load("@io_bazel_rules_go//go:def.bzl", "go_rule")

def _codegen_impl(ctx):
    args = ctx.actions.args()
    args.add("-config", ctx.file.config.path)
    args.add("-out", ctx.outputs.out.path)
    args.add("-package", ctx.attr.package)
    ctx.actions.run(
        inputs = [ctx.file._template, ctx.file.config],
        outputs = [ctx.outputs.out],
        executable = ctx.executable._generator,
        tools = [ctx.executable._generator],
        arguments = [args],
        mnemonic = "SmallFactory",
    )
    return [
        DefaultInfo(files = depset([ctx.outputs.out])),
    ]

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
        "out": attr.output(
            mandatory = True,
        ),
    },
)

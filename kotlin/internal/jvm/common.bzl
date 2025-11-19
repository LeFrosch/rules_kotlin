load(
    "//kotlin/internal:opts.bzl",
    _javac_options_to_flags = "javac_options_to_flags",
)
load(
    "//kotlin/internal/jvm:compile.bzl",
    _compile_util = "compile",
)
load(
    "//kotlin/internal/jvm:associates.bzl", 
    _associate_utils = "associate_utils",
)
load(
    "//kotlin/internal:defs.bzl",
    _TOOLCHAIN_TYPE = "TOOLCHAIN_TYPE",
)

def _compile(
        ctx,
        output,
        kt_toolchain,
        java_toolchain,
        java_runtime,
        output_source_jar = None,
        output_compile_jar = None,
        javac_opts = None,
        source_jars = None,
        resource_jars = None,
        kt_source_files = None,
        java_source_files = None,
        plugins = None,
        deps = None,
        additional_deps = None,
        runtime_deps = None,
        associate_deps = None,
        exports = None,
        neverlink = False,
        module_name = None,
        tags = None,
        jdeps = None):
    """Compiles Kotlin/Java source files/jars from the implementation of a Starlark rule.

    Args:
        ctx: (RuleContext) The rule context.
        output: (File) The output of compilation. Mandatory.
        java_toolchain: (JavaToolchainInfo) Toolchain to be used for this compilation. Mandatory.
        java_runtime: (JavaRuntimeInfo) Runtime used by the internal implementation. Mandatory.
        kt_toolchain: (ToolchainInfo) Toolchain to be sued for this compilation. Mandatory.
        javac_opts: ([str]) A list of the desired javac options. Optional.
        source_jars: ([File]) A list of the jars to be compiled. At least one of source_jars or
            kt_source_files or java_source_files should be specified.
        resource_jars: ([File]) A list of archives containing Java resources. Optional.
        kt_source_files: ([File]) A list of the Kotlin source files to be compiled. At least one of
            source_jars or kt_source_files or java_source_files should be specified.
        java_source_files: ([File]) A list of the Java source files to be compiled. At least one of
            source_jars or kt_source_files or java_source_files should be specified.
        output_source_jar: (File) The output source jar. Optional. Defaults to `{output}-src.jar`.
        output_compile_jar: (File) The class jar. Optional. Defaults. to `{output}-abi.jar`.
        jdeps: (File) jdeps information for the rule output (if available). This should be a binary
            proto encoded using the deps.proto protobuf included with Bazel. If available this file
            is typically produced by a compiler. Optional. Defaults to `{output}.jdeps`.
        plugins: ([Target]) A list of plugins. Optional.
        deps: ([Target]) A list of dependencies. Optional.
        additional_deps: ([JavaInfo]) Because of the provider duality used by this rule set it is
            more convenient to work with targets most of the time. However, to support dependencies
            which are not targets this list exists. Optional.
        runtime_deps: ([Target]) A list of runtime dependencies. Optional.
        associate_deps: ([Target]) A list of dependencies who should be considered part of the same 
            module. Optional.
        exports: ([Target]) A list of exports. Optional.
        neverlink: (bool) Only use this library for compilation and not at runtime. Default false.
        tags: ([String]) A list of tags. Some behaviour can be toggled with tags. Optional.
        module_name: (String) The name of the module. Optional. Default is derived from the label.

    Returns:
        (JavaInfo)
    """
    base_name = output.basename.removesuffix(".jar")

    # kt = ctx.toolchains[_TOOLCHAIN_TYPE],
    # java = find_java_toolchain(ctx, ctx.attr._java_toolchain),
    # java_runtime = find_java_runtime_toolchain(ctx, ctx.attr._host_javabase),
    # /home/daniel_brauner/Projects/bazel/rules_kotlin

    # TODO: this still access ctx.attr.module_name, should be passed in explicitly
    associates = _associate_utils.get_associates(
        ctx,
        toolchains = struct(
            kt = kt_toolchain,
            java = java_toolchain,
            java_runtime = java_runtime,
        ),
        associates = associate_deps or [], 
    )

    return _compile_util.run_compile_action(
        ctx,
        rule_kind = "kt_jvm_library",
        output = output,
        output_source_jar = output_source_jar or ctx.actions.declare_file(base_name + "-src.jar"),
        output_compile_jar = output_compile_jar or ctx.actions.declare_file(base_name + ".abi.jar"),
        kt_toolchain = kt_toolchain,
        java_toolchain = java_toolchain,
        java_runtime = java_runtime,
        kotlinc_opts = kt_toolchain.kotlinc_options,
        javac_opts = javac_opts or _javac_options_to_flags(kt_toolchain.javac_options),
        source_jars = source_jars or [],
        resource_jars = resource_jars or [],
        kt_source_files = kt_source_files or [],
        java_source_files = java_source_files or [],
        plugins = plugins or [],
        deps = (deps or []) + (associate_deps or []),
        additional_deps = additional_deps or [],
        runtime_deps = runtime_deps or [],
        associates = associates,
        exports = exports or [],
        neverlink = neverlink,
        module_name = module_name,
        tags = tags or [],
        jdeps = jdeps or ctx.actions.declare_file(base_name + ".jdeps"),
    )

def _find_kotlin_toolchain(ctx):
    return ctx.toolchains[_TOOLCHAIN_TYPE]

kt_jvm_common = struct(
    compile = _compile,
    find_kotlin_toolchain = _find_kotlin_toolchain,
    TOOLCHAIN_TYPE = _TOOLCHAIN_TYPE,
)

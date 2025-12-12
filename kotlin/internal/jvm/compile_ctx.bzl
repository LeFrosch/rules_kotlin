# Copyright 2018 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
load(
    "@rules_java//java:defs.bzl",
    "JavaInfo",
    "java_common",
)
load(
    "//kotlin/internal:defs.bzl",
    _JAVA_RUNTIME_TOOLCHAIN_TYPE = "JAVA_RUNTIME_TOOLCHAIN_TYPE",
    _JAVA_TOOLCHAIN_TYPE = "JAVA_TOOLCHAIN_TYPE",
    _KtCompilerPluginInfo = "KtCompilerPluginInfo",
    _KtJvmInfo = "KtJvmInfo",
    _KtPluginConfiguration = "KtPluginConfiguration",
    _TOOLCHAIN_TYPE = "TOOLCHAIN_TYPE",
)
load(
    "//kotlin/internal:opts.bzl",
    "JavacOptions",
    "KotlincOptions",
    "javac_options_to_flags",
    "kotlinc_options_to_flags",
)
load(
    "//kotlin/internal/jvm:associates.bzl",
    _associate_utils = "associate_utils",
)
load(
    "//kotlin/internal/jvm:jvm_deps.bzl",
    _jvm_deps_utils = "jvm_deps_utils",
)
load(
    "//kotlin/internal/jvm:plugins.bzl",
    "is_ksp_processor_generating_java",
    _plugin_mappers = "mappers",
)
load(
    "//kotlin/internal/utils:sets.bzl",
    _sets = "sets",
)
load(
    "//kotlin/internal/utils:utils.bzl",
    _utils = "utils",
)

# UTILITY ##############################################################################################################
def find_java_toolchain(ctx, target):
    if _JAVA_TOOLCHAIN_TYPE in ctx.toolchains:
        return ctx.toolchains[_JAVA_TOOLCHAIN_TYPE].java
    return target[java_common.JavaToolchainInfo]

def find_java_runtime_toolchain(ctx, target):
    if _JAVA_RUNTIME_TOOLCHAIN_TYPE in ctx.toolchains:
        return ctx.toolchains[_JAVA_RUNTIME_TOOLCHAIN_TYPE].java_runtime
    return target[java_common.JavaRuntimeInfo]

def _java_info(target):
    return target[JavaInfo] if JavaInfo in target else None

def _java_infos(target_list):
    """Extract JavaInfo providers from a list of targets."""
    return [target[JavaInfo] for target in target_list if JavaInfo in target]

def _jvm_deps(kt_toolchain, deps, additional_deps, associates, tags):
    """Computes the compilation classpath.

    Handles experimental_prune_transitive_deps and filters out associate ABI jars.

    Args:
        kt_toolchain: The Kotlin toolchain.
        deps: List of dependency targets.
        additional_deps: List of JavaInfo providers for synthetic dependencies.
        associates: Struct from _get_associates() with deps, jars, abi_jar_set fields.
        tags: List of tags for experimental feature checks.

    Returns:
        A depset of compilation jars.
    """
    dep_infos = additional_deps + _java_infos(deps) + _java_infos(associates.deps)

    # Reduced classpath, exclude transitive deps from compilation
    if kt_toolchain.experimental_prune_transitive_deps and not "kt_experimental_prune_transitive_deps_incompatible" in tags:
        transitive = [d.compile_jars for d in dep_infos]
    else:
        transitive = [d.compile_jars for d in dep_infos] + [d.transitive_compile_time_jars for d in dep_infos]

    compile_depset_list = depset(transitive = transitive + [associates.jars]).to_list()
    compile_depset_list_filtered = [jar for jar in compile_depset_list if not _sets.contains(associates.abi_jar_set, jar)]

    return struct(
        deps = dep_infos,
        compile_jars = depset(compile_depset_list_filtered),
        associate_jars = associates.jars,
    )

def _deps_artifacts(kt_toolchain, targets):
    """Collect Jdeps artifacts if required.

    Args:
        kt_toolchain: The Kotlin toolchain (or a struct with kt field for backward compatibility).
        targets: List of targets to collect jdeps from.

    Returns:
        A depset of jdeps artifacts.
    """
    if not kt_toolchain.experimental_report_unused_deps == "off":
        deps_artifacts = [t[JavaInfo].outputs.jdeps for t in targets if JavaInfo in t and t[JavaInfo].outputs.jdeps]
    else:
        deps_artifacts = []

    return depset(deps_artifacts)

def _partitioned_srcs(srcs):
    """Creates a struct of srcs sorted by extension. Fails if there are no sources."""
    kt_srcs = []
    java_srcs = []
    src_jars = []

    for f in srcs:
        if f.path.endswith(".kt"):
            kt_srcs.append(f)
        elif f.path.endswith(".java"):
            java_srcs.append(f)
        elif f.path.endswith(".srcjar"):
            src_jars.append(f)

    return struct(
        kt = kt_srcs,
        java = java_srcs,
        all_srcs = kt_srcs + java_srcs,
        src_jars = src_jars,
    )

def _compiler_toolchains(ctx):
    """Creates a struct of the relevant compilation toolchains"""
    return struct(
        kt = ctx.toolchains[_TOOLCHAIN_TYPE],
        java = find_java_toolchain(ctx, ctx.attr._java_toolchain),
        java_runtime = find_java_runtime_toolchain(ctx, ctx.attr._host_javabase),
    )

def _create_compilation_context(
        kt_toolchain,
        java_toolchain,
        java_runtime,
        module_name,
        kotlinc_opts,
        javac_opts,
        source_jars,
        resource_jars,
        kt_source_files,
        java_source_files,
        plugins,
        deps,
        additional_deps,
        runtime_deps,
        associates,
        exports,
        neverlink,
        tags):
    """Creates a compilation context struct.

    This struct encapsulates all parameters needed for compilation,
    computed from the raw inputs.

    Args:
        kt_toolchain: The Kotlin toolchain.
        java_toolchain: The Java toolchain.
        java_runtime: The Java runtime.
        module_name: The module name.
        kotlinc_opts: KotlincOptions provider or None.
        javac_opts: List of javac option strings.
        source_jars: List of source jar files.
        resource_jars: List of resource jar files.
        kt_source_files: List of Kotlin source files.
        java_source_files: List of Java source files.
        plugins: List of plugin targets.
        deps: List of dependency targets.
        additional_deps: List of JavaInfo providers for synthetic dependencies.
        runtime_deps: List of runtime dependency targets.
        associates: List of associate targets.
        exports: List of exported dependency targets.
        neverlink: Whether this is a compile-only library.
        tags: List of tags for experimental feature checks.

    Returns:
        A struct containing all compilation parameters and pre-computed values.
    """
    associates_info = _associate_utils.get_associates(kt_toolchain, tags, associates)

    # Use associate module name if available, otherwise use provided module_name
    final_module_name = associates_info.module_name or module_name
    if not final_module_name:
        fail("module_name must be provided when no associates are present")

    return struct(
        kt_toolchain = kt_toolchain,
        java_toolchain = java_toolchain,
        java_runtime = java_runtime,
        module_name = final_module_name,
        kotlinc_opts = kotlinc_opts or kt_toolchain.kotlinc_options,
        javac_opts = javac_opts or kt_toolchain.javac_options,
        source_jars = source_jars,
        resource_jars = resource_jars,
        kt_source_files = kt_source_files,
        java_source_files = java_source_files,
        deps = deps,
        additional_deps = additional_deps,
        runtime_deps = runtime_deps,
        plugin_info = _new_plugins_from(plugins + _exported_plugins(deps)),
        exports = exports,
        neverlink = neverlink,
        tags = tags,
        compile_deps = _jvm_deps(kt_toolchain, deps, additional_deps, associates_info, tags),
        deps_artifacts = _deps_artifacts(kt_toolchain, deps + associates),
        annotation_processors = _plugin_mappers.targets_to_annotation_processors(plugins + deps),
        ksp_annotation_processors = _plugin_mappers.targets_to_ksp_annotation_processors(plugins + deps),
        transitive_runtime_jars = _plugin_mappers.targets_to_transitive_runtime_jars(plugins + deps),
    )

def _create_compilation_context_from_ctx(ctx, extra_resources):
    """Creates compilation context from rule ctx (backward compatibility helper).

    Internal rules use this to create context from their rule ctx.

    Args:
        ctx: The rule context.
        extra_resources: Additional resources put into the resource jar.

    Returns:
        A compilation context struct.
    """
    partitioned_srcs = _partitioned_srcs(ctx.files.srcs)
    toolchains = _compiler_toolchains(ctx)

    module_name = getattr(ctx.attr, "module_name", "") or _utils.derive_module_name(ctx.label, "")

    resource_jars = list(ctx.files.resource_jars)
    if len(ctx.files.resources) + len(extra_resources) > 0:
        resource_jars.append(_build_resourcejar_action(ctx, extra_resources))

    return _create_compilation_context(
        kt_toolchain = toolchains.kt,
        java_toolchain = toolchains.java,
        java_runtime = toolchains.java_runtime,
        module_name = module_name,
        kotlinc_opts = ctx.attr.kotlinc_opts[KotlincOptions] if ctx.attr.kotlinc_opts else None,
        javac_opts = ctx.attr.javac_opts[JavacOptions] if ctx.attr.javac_opts else None,
        source_jars = partitioned_srcs.src_jars,
        resource_jars = resource_jars,
        kt_source_files = partitioned_srcs.kt,
        java_source_files = partitioned_srcs.java,
        plugins = ctx.attr.plugins,
        deps = ctx.attr.deps,
        additional_deps = [toolchains.kt.jvm_stdlibs],
        runtime_deps = getattr(ctx.attr, "runtime_deps", []),
        associates = getattr(ctx.attr, "associates", []),
        exports = getattr(ctx.attr, "exports", []),
        neverlink = getattr(ctx.attr, "neverlink", False),
        tags = ctx.attr.tags,
    )

def _fail_if_invalid_associate_deps(associate_deps, deps):
    """Verifies associates not included in target deps."""
    diff = _sets.intersection(
        _sets.copy_of([x.label for x in associate_deps]),
        _sets.copy_of([x.label for x in deps]),
    )
    if diff:
        fail(
            "\n------\nTargets should only be put in associates= or deps=, not both:\n%s" %
            ",\n ".join(["    %s" % x for x in list(diff)]),
        )

def _java_infos_to_compile_jars(java_infos):
    return depset(transitive = [j.compile_jars for j in java_infos])

def _exported_plugins(deps):
    """Encapsulates compiler dependency metadata."""
    plugins = []
    for dep in deps:
        if _KtJvmInfo in dep and dep[_KtJvmInfo] != None:
            plugins.extend(dep[_KtJvmInfo].exported_compiler_plugins.to_list())
    return plugins

def _collect_plugins_for_export(local, exports):
    """Collects into a depset. """
    return depset(
        local,
        transitive = [
            e[_KtJvmInfo].exported_compiler_plugins
            for e in exports
            if _KtJvmInfo in e and e[_KtJvmInfo]
        ],
    )

_CONVENTIONAL_RESOURCE_PATHS = [
    "src/main/java",
    "src/main/resources",
    "src/test/java",
    "src/test/resources",
    "kotlin",
]

def _adjust_resources_path_by_strip_prefix(path, resource_strip_prefix):
    if not path.startswith(resource_strip_prefix):
        fail("Resource file %s is not under the specified prefix to strip %s" % (path, resource_strip_prefix))

    clean_path = path[len(resource_strip_prefix):]
    return clean_path

def _adjust_resources_path_by_default_prefixes(path):
    for cp in _CONVENTIONAL_RESOURCE_PATHS:
        _, _, rel_path = path.partition(cp)
        if rel_path:
            return rel_path
    return path

def _adjust_resources_path(path, resource_strip_prefix):
    if resource_strip_prefix:
        return _adjust_resources_path_by_strip_prefix(path, resource_strip_prefix)
    else:
        return _adjust_resources_path_by_default_prefixes(path)

def _format_compile_plugin_options(o):
    """Format compiler option into id:value for cmd line."""
    return [
        "%s:%s" % (o.id, o.value),
    ]

def _new_plugins_from(targets):
    """Returns a struct containing the plugin metadata for the given targets.

    Args:
        targets: A list of targets.
    Returns:
        A struct containing the plugins for the given targets in the format:
        {
            stubs_phase = {
                classpath = depset,
                options= List[KtCompilerPluginOption],
            ),
            compile = {
                classpath = depset,
                options = List[KtCompilerPluginOption],
            },
        }
    """

    all_plugins = {}
    plugins_without_phase = []
    for t in targets:
        if _KtCompilerPluginInfo not in t:
            continue
        plugin = t[_KtCompilerPluginInfo]
        if not (plugin.stubs or plugin.compile):
            plugins_without_phase.append("%s: %s" % (t.label, plugin.id))
        if plugin.id in all_plugins and all_plugins[plugin.id] != plugin:
            # This need a more robust error messaging.
            fail("has multiple plugins with the same id: %s." % plugin.id)
        all_plugins[plugin.id] = plugin

    if plugins_without_phase:
        fail("has plugin without a phase defined: %s" % cfgs_without_plugin)

    all_plugin_cfgs = {}
    cfgs_without_plugin = []
    for t in targets:
        if _KtPluginConfiguration not in t:
            continue
        cfg = t[_KtPluginConfiguration]
        if cfg.id not in all_plugins:
            cfgs_without_plugin.append("%s: %s" % (t.label, cfg.id))
        all_plugin_cfgs.setdefault(cfg.id, []).append(cfg)

    if cfgs_without_plugin:
        fail("has plugin configurations without corresponding plugins: %s" % cfgs_without_plugin)

    return struct(
        plugins = targets,
        stubs_phase = _new_plugin_from(all_plugin_cfgs, [p for p in all_plugins.values() if p.stubs]),
        compile_phase = _new_plugin_from(all_plugin_cfgs, [p for p in all_plugins.values() if p.compile]),
    )

def _new_plugin_from(all_cfgs, plugins_for_phase):
    classpath = []
    data = []
    options = []
    for p in plugins_for_phase:
        classpath.append(p.classpath)
        options.extend(p.options)
        if p.id in all_cfgs:
            cfg = p.merge_cfgs(p, all_cfgs[p.id])
            classpath.append(cfg.classpath)
            data.append(cfg.data)
            options.extend(cfg.options)

    return struct(
        classpath = depset(transitive = classpath),
        data = depset(transitive = data),
        options = options,
    )

# INTERNAL ACTIONS #####################################################################################################
def _fold_jars_action(ctx, rule_kind, toolchains, output_jar, input_jars, action_type = ""):
    """Set up an action to Fold the input jars into a normalized output jar."""
    args = ctx.actions.args()
    args.add_all([
        "--normalize",
        "--compression",
        "--exclude_build_data",
        "--add_missing_directories",
    ])
    args.add_all([
        "--deploy_manifest_lines",
        "Target-Label: %s" % str(ctx.label),
        "Injecting-Rule-Kind: %s" % rule_kind,
    ])
    args.add("--output", output_jar)
    args.add_all(input_jars, before_each = "--sources")
    ctx.actions.run(
        mnemonic = "KotlinFoldJars" + action_type,
        inputs = input_jars,
        outputs = [output_jar],
        executable = toolchains.java.single_jar,
        arguments = [args],
        progress_message = "Merging Kotlin output jar %%{label}%s from %d inputs" % (
            "" if not action_type else " (%s)" % action_type,
            len(input_jars),
        ),
        toolchain = _TOOLCHAIN_TYPE,
    )

def _resourcejar_args_action(ctx, extra_resources = {}):
    res_cmd = []

    # Get the strip prefix from the File object if provided
    strip_prefix = None
    if ctx.file.resource_strip_prefix:
        file = ctx.file.resource_strip_prefix
        file_path = file.path

        # Assume that strip_prefix has the same root as the resources
        if ctx.files.resources and file.root.path != ctx.files.resources[0].root.path:
            # Strip prefix root mismatch
            file_path = file_path[len(file.root.path):]

        # if dirname starts with ctx.label.package, we need to remove ctx.label.package, because it means that
        # we've hit the edge case when there is a target with the same name as the package
        if file.dirname.startswith(ctx.label.package + "/"):
            strip_prefix = file_path[len(ctx.label.package) + 1:]
        else:
            strip_prefix = file_path

        if ctx.files.resources and file.root.path != ctx.files.resources[0].root.path:
            # Add back the root path to align with resources paths
            strip_prefix = ctx.files.resources[0].root.path + "/" + strip_prefix

    for f in ctx.files.resources:
        target_path = _adjust_resources_path(f.path, strip_prefix)
        if target_path[0] == "/":
            target_path = target_path[1:]
        line = "{target_path}={f_path}\n".format(
            target_path = target_path,
            f_path = f.path,
        )
        res_cmd.extend([line])

    for key, value in extra_resources.items():
        target_path = _adjust_resources_path(value.short_path, ctx.label.package)
        if target_path[0] == "/":
            target_path = target_path[1:]
        line = "{target_path}={res_path}\n".format(
            res_path = value.path,
            target_path = key,
        )
        res_cmd.extend([line])

    zipper_args_file = ctx.actions.declare_file("%s_resources_zipper_args" % ctx.label.name)
    ctx.actions.write(zipper_args_file, "".join(res_cmd))
    return zipper_args_file

def _build_resourcejar_action(ctx, extra_resources = {}):
    """sets up an action to build a resource jar for the target being compiled.
    Returns:
        The file resource jar file.
    """
    resources_jar_output = ctx.actions.declare_file(ctx.label.name + "-resources.jar")
    zipper_args = _resourcejar_args_action(ctx, extra_resources)
    ctx.actions.run(
        mnemonic = "KotlinZipResourceJar",
        executable = ctx.executable._zipper,
        inputs = ctx.files.resources + extra_resources.values() + [zipper_args],
        outputs = [resources_jar_output],
        arguments = [
            "c",
            resources_jar_output.path,
            "@" + zipper_args.path,
        ],
        progress_message = "Creating intermediate resource jar %{label}",
    )
    return resources_jar_output

def _run_merge_jdeps_action(ctx, toolchains, jdeps, outputs, deps):
    """Creates a Jdeps merger action invocation."""
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("--flagfile=%s", use_always = True)

    args.add("--target_label", ctx.label)

    for f, path in outputs.items():
        args.add("--" + f, path)

    args.add_all("--inputs", jdeps, omit_if_empty = True)
    args.add("--report_unused_deps", toolchains.kt.experimental_report_unused_deps)

    mnemonic = "JdepsMerge"
    progress_message = "%s %%{label} { jdeps: %d }" % (
        mnemonic,
        len(jdeps),
    )

    inputs = depset(jdeps)
    if not toolchains.kt.experimental_report_unused_deps == "off":
        # For sandboxing to work, and for this action to be deterministic, the compile jars need to be passed as inputs
        inputs = depset(jdeps, transitive = [depset([], transitive = [dep.transitive_compile_time_jars for dep in deps])])

    ctx.actions.run(
        mnemonic = mnemonic,
        inputs = inputs,
        tools = [toolchains.kt.jdeps_merger.files_to_run, toolchains.kt.jvm_stdlibs.compile_jars],
        outputs = [f for f in outputs.values()],
        executable = toolchains.kt.jdeps_merger.files_to_run.executable,
        execution_requirements = toolchains.kt.execution_requirements,
        arguments = [
            ctx.actions.args().add_all(toolchains.kt.builder_args),
            args,
        ],
        progress_message = progress_message,
        toolchain = _TOOLCHAIN_TYPE,
    )

def _run_kapt_builder_actions(
        ctx,
        compilation_ctx,
        rule_kind):
    """Runs KAPT using the KotlinBuilder tool.

    Args:
        ctx: Rule context.
        compilation_ctx: Compilation context struct.
        rule_kind: The rule kind (e.g., "kt_jvm_library").
        annotation_processors: List of annotation processor targets.

    Returns:
        A struct containing KAPT outputs.
    """
    ap_generated_src_jar = ctx.actions.declare_file(ctx.label.name + "-kapt-gensrc.jar")
    kapt_generated_stub_jar = ctx.actions.declare_file(ctx.label.name + "-kapt-generated-stub.jar")
    kapt_generated_class_jar = ctx.actions.declare_file(ctx.label.name + "-kapt-generated-class.jar")

    _run_kt_builder_action(
        ctx = ctx,
        compilation_ctx = compilation_ctx,
        rule_kind = rule_kind,
        mnemonic = "KotlinKapt",
        outputs = {
            "generated_java_srcjar": ap_generated_src_jar,
            "kapt_generated_class_jar": kapt_generated_class_jar,
            "kapt_generated_stub_jar": kapt_generated_stub_jar,
        },
        generated_src_jars = [],
        annotation_processors = compilation_ctx.annotation_processors,
        build_kotlin = False,
    )

    return struct(
        ap_generated_src_jar = ap_generated_src_jar,
        kapt_generated_stub_jar = kapt_generated_stub_jar,
        kapt_generated_class_jar = kapt_generated_class_jar,
    )

def _run_ksp_builder_actions(
        ctx,
        compilation_ctx):
    """Runs KSP2 via a dedicated KSP2 worker.

    The worker handles all staging, KSP2 execution, and output packaging internally.
    This eliminates tree artifacts and reduces the action count to a single action.

    Args:
        ctx: Rule context.
        compilation_ctx: Compilation context struct.
        transitive_runtime_jars: Depset of transitive runtime jars from plugins.

    Returns:
        A struct containing KSP outputs (two JAR files: sources and classes)
    """

    # Output JARs - the worker creates these directly
    ksp_generated_java_srcjar = ctx.actions.declare_file(ctx.label.name + "-ksp-gensrc.jar")
    ksp_generated_classes_jar = ctx.actions.declare_file(ctx.label.name + "-ksp-genclasses.jar")

    # Build arguments for KSP2 worker (flagfile format)
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("--flagfile=%s", use_always = True)

    args.add("--module_name", compilation_ctx.module_name)

    # Pass source files directly - worker will stage them internally
    all_source_files = compilation_ctx.kt_source_files + compilation_ctx.java_source_files
    if all_source_files:
        args.add_all("--sources", all_source_files)

    # Pass srcjars - worker will unpack them internally
    if compilation_ctx.source_jars:
        args.add_all("--source_jars", compilation_ctx.source_jars)

    # Output JAR paths
    args.add("--generated_sources_output", ksp_generated_java_srcjar.path)
    args.add("--generated_classes_output", ksp_generated_classes_jar.path)

    # Compiler settings
    args.add("--jvm_target", compilation_ctx.kt_toolchain.jvm_target)
    args.add("--language_version", compilation_ctx.kt_toolchain.language_version)
    args.add("--api_version", compilation_ctx.kt_toolchain.api_version)
    args.add("--jdk_home", compilation_ctx.java_runtime.java_home)

    # Add libraries (classpath)
    if compilation_ctx.compile_deps.deps:
        args.add_all("--libraries", compilation_ctx.compile_deps.deps)

    # Collect KSP2 API JARs (needed by the worker to load KSP2 classes via reflection)
    ksp2_api_jars = depset(
        ctx.attr._ksp2_symbol_processing_api[JavaInfo].runtime_output_jars +
        ctx.attr._ksp2_symbol_processing_aa[JavaInfo].runtime_output_jars +
        ctx.attr._ksp2_symbol_processing_common_deps[JavaInfo].runtime_output_jars +
        ctx.attr._ksp2_kotlinx_coroutines[JavaInfo].runtime_output_jars,
    )

    # Get the KSP2 invoker JAR (contains Ksp2Invoker class loaded via reflection)
    ksp2_invoker_jars = compilation_ctx.kt_toolchain.ksp2_invoker[JavaInfo].runtime_output_jars

    # Add processor JARs - includes KSP2 API JARs, invoker JAR, and user processor JARs
    args.add_all("--processor_classpath", ksp2_invoker_jars)
    args.add_all("--processor_classpath", ksp2_api_jars)
    if compilation_ctx.transitive_runtime_jars:
        args.add_all("--processor_classpath", compilation_ctx.transitive_runtime_jars)

    # Run KSP2 via dedicated worker (separate from kotlinc worker)
    # Single action: staging + KSP2 + packaging all happen in the worker
    ctx.actions.run(
        mnemonic = "KotlinKsp2",
        inputs = depset(
            direct = all_source_files + compilation_ctx.source_jars + ksp2_invoker_jars,
            transitive = [
                compilation_ctx.compile_deps.compile_jars,
                compilation_ctx.transitive_runtime_jars,
                compilation_ctx.java_runtime.files,
                ksp2_api_jars,
            ],
        ),
        tools = [
            compilation_ctx.kt_toolchain.ksp2.files_to_run,
            compilation_ctx.kt_toolchain.jvm_stdlibs.compile_jars,
        ],
        outputs = [ksp_generated_java_srcjar, ksp_generated_classes_jar],
        executable = compilation_ctx.kt_toolchain.ksp2.files_to_run.executable,
        execution_requirements = _utils.add_dicts(
            compilation_ctx.kt_toolchain.execution_requirements,
            {"worker-key-mnemonic": "KotlinKsp2"},
        ),
        arguments = [
            ctx.actions.args().add_all(compilation_ctx.kt_toolchain.builder_args),
            args,
        ],
        progress_message = "Running KSP2 for %{label}",
        toolchain = _TOOLCHAIN_TYPE,
    )

    return struct(
        ksp_generated_class_jar = ksp_generated_classes_jar,
        ksp_generated_src_jar = ksp_generated_java_srcjar,
    )

def _run_kt_builder_action(
        ctx,
        compilation_ctx,
        rule_kind,
        mnemonic,
        outputs,
        generated_src_jars,
        annotation_processors,
        build_kotlin = True):
    """Creates a KotlinBuilder action invocation.

    Args:
        ctx: Rule context.
        compilation_ctx: Compilation context struct from _create_compilation_context().
        rule_kind: The rule kind (e.g., "kt_jvm_library").
        mnemonic: The action mnemonic (e.g., "KotlinCompile", "KotlinKapt").
        outputs: Dict of output file paths.
        generated_src_jars: List of generated source jars (from KAPT/KSP).
        annotation_processors: List of annotation processor targets.
        build_kotlin: Whether to build Kotlin sources (default True).
    """
    if not mnemonic:
        fail("Error: A `mnemonic` must be provided for every invocation of `_run_kt_builder_action`!")

    # Inline _utils.init_args() logic - build args object directly
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("--flagfile=%s", use_always = True)

    args.add("--target_label", ctx.label)
    args.add("--rule_kind", rule_kind)
    args.add("--kotlin_module_name", compilation_ctx.module_name)

    kotlinc_options = compilation_ctx.kotlinc_opts if compilation_ctx.kotlinc_opts else compilation_ctx.kt_toolchain.kotlinc_options
    kotlin_jvm_target = kotlinc_options.jvm_target if kotlinc_options.jvm_target else compilation_ctx.kt_toolchain.jvm_target
    args.add("--kotlin_jvm_target", kotlin_jvm_target)
    args.add("--kotlin_api_version", compilation_ctx.kt_toolchain.api_version)
    args.add("--kotlin_language_version", compilation_ctx.kt_toolchain.language_version)

    debug = compilation_ctx.kt_toolchain.debug
    for tag in compilation_ctx.tags:
        if tag == "trace":
            debug = debug + [tag]
        if tag == "timings":
            debug = debug + [tag]
    args.add_all("--kotlin_debug_tags", debug, omit_if_empty = False)

    for f, path in outputs.items():
        args.add("--" + f, path)

    all_srcs = compilation_ctx.kt_source_files + compilation_ctx.java_source_files

    # Unwrap kotlinc_options/javac_options or default to the ones being provided by the toolchain
    args.add_all("--kotlin_passthrough_flags", kotlinc_options_to_flags(kotlinc_options))
    args.add_all("--javacopts", javac_options_to_flags(compilation_ctx.javac_opts))
    args.add_all("--direct_dependencies", _java_infos_to_compile_jars(compilation_ctx.compile_deps.deps))
    args.add("--strict_kotlin_deps", compilation_ctx.kt_toolchain.experimental_strict_kotlin_deps)
    args.add_all("--classpath", compilation_ctx.compile_deps.compile_jars)
    args.add("--reduced_classpath_mode", compilation_ctx.kt_toolchain.experimental_reduce_classpath_mode)
    args.add("--build_tools_api", compilation_ctx.kt_toolchain.experimental_build_tools_api)
    args.add_all("--sources", all_srcs, omit_if_empty = True)
    args.add_all("--source_jars", compilation_ctx.source_jars + generated_src_jars, omit_if_empty = True)
    args.add_all("--deps_artifacts", compilation_ctx.deps_artifacts, omit_if_empty = True)
    args.add_all("--kotlin_friend_paths", compilation_ctx.compile_deps.associate_jars, omit_if_empty = True)
    args.add("--instrument_coverage", ctx.coverage_instrumented())

    # Compute plugins from compilation_ctx

    # Collect and prepare plugin descriptor for the worker.
    args.add_all(
        "--processors",
        annotation_processors,
        map_each = _plugin_mappers.kt_plugin_to_processor,
        omit_if_empty = True,
        uniquify = True,
    )

    args.add_all(
        "--processorpath",
        annotation_processors,
        map_each = _plugin_mappers.kt_plugin_to_processorpath,
        omit_if_empty = True,
        uniquify = True,
    )

    args.add_all(
        "--stubs_plugin_classpath",
        compilation_ctx.plugin_info.stubs_phase.classpath,
        omit_if_empty = True,
    )

    args.add_all(
        "--stubs_plugin_options",
        compilation_ctx.plugin_info.stubs_phase.options,
        map_each = _format_compile_plugin_options,
        omit_if_empty = True,
    )

    args.add_all(
        "--compiler_plugin_classpath",
        compilation_ctx.plugin_info.compile_phase.classpath,
        omit_if_empty = True,
    )

    args.add_all(
        "--compiler_plugin_options",
        compilation_ctx.plugin_info.compile_phase.options,
        map_each = _format_compile_plugin_options,
        omit_if_empty = True,
    )

    if not "kt_remove_private_classes_in_abi_plugin_incompatible" in compilation_ctx.tags and compilation_ctx.kt_toolchain.experimental_remove_private_classes_in_abi_jars == True:
        args.add("--remove_private_classes_in_abi_jar", "true")

    if not "kt_treat_internal_as_private_in_abi_plugin_incompatible" in compilation_ctx.tags and compilation_ctx.kt_toolchain.experimental_treat_internal_as_private_in_abi_jars == True:
        if not "kt_remove_private_classes_in_abi_plugin_incompatible" in compilation_ctx.tags and compilation_ctx.kt_toolchain.experimental_remove_private_classes_in_abi_jars == True:
            args.add("--treat_internal_as_private_in_abi_jar", "true")
        else:
            fail(
                "experimental_treat_internal_as_private_in_abi_jars without experimental_remove_private_classes_in_abi_jars is invalid." +
                "\nTo remove internal symbols from kotlin abi jars ensure experimental_remove_private_classes_in_abi_jars " +
                "and experimental_treat_internal_as_private_in_abi_jars are both enabled in define_kt_toolchain." +
                "\nAdditionally ensure the target does not contain the kt_remove_private_classes_in_abi_plugin_incompatible tag.",
            )

    if not "kt_remove_debug_info_in_abi_plugin_incompatible" in compilation_ctx.tags and compilation_ctx.kt_toolchain.experimental_remove_debug_info_in_abi_jars == True:
        args.add("--remove_debug_info_in_abi_jar", "true")

    args.add("--build_kotlin", build_kotlin)

    progress_message = "%s %%{label} { kt: %d, java: %d, srcjars: %d } for %s" % (
        mnemonic,
        len(compilation_ctx.kt_source_files),
        len(compilation_ctx.java_source_files),
        len(compilation_ctx.source_jars),
        ctx.var.get("TARGET_CPU", "UNKNOWN CPU"),
    )

    ctx.actions.run(
        mnemonic = mnemonic,
        inputs = depset(
            all_srcs + compilation_ctx.source_jars + generated_src_jars,
            transitive = [
                compilation_ctx.compile_deps.associate_jars,
                compilation_ctx.compile_deps.compile_jars,
                compilation_ctx.transitive_runtime_jars,
                compilation_ctx.deps_artifacts,
                compilation_ctx.plugin_info.stubs_phase.classpath,
                compilation_ctx.plugin_info.compile_phase.classpath,
            ],
        ),
        tools = [
            compilation_ctx.kt_toolchain.kotlinbuilder.files_to_run,
            compilation_ctx.kt_toolchain.kotlin_home.files_to_run,
        ],
        outputs = [f for f in outputs.values()],
        executable = compilation_ctx.kt_toolchain.kotlinbuilder.files_to_run.executable,
        execution_requirements = _utils.add_dicts(
            compilation_ctx.kt_toolchain.execution_requirements,
            {"worker-key-mnemonic": mnemonic},
        ),
        arguments = [ctx.actions.args().add_all(compilation_ctx.kt_toolchain.builder_args), args],
        progress_message = progress_message,
        env = {
            "LC_CTYPE": "en_US.UTF-8",  # For Java source files
            "REPOSITORY_NAME": _utils.builder_workspace_name(ctx),
        },
        toolchain = _TOOLCHAIN_TYPE,
    )

# MAIN ACTIONS #########################################################################################################

def _kt_jvm_produce_jar_actions(ctx, rule_kind, extra_resources = {}):
    """Setup The actions to compile a jar and if any resources or resource_jars were provided to merge these in with the
    compilation output.

    Returns:
        see `kt_jvm_compile_action`.
    """
    deps = getattr(ctx.attr, "deps", [])
    associates = getattr(ctx.attr, "associates", [])
    _fail_if_invalid_associate_deps(associates, deps)
    compile_deps = _jvm_deps_utils.jvm_deps(
        ctx,
        toolchains = _compiler_toolchains(ctx),
        associate_deps = associates,
        deps = deps,
        exports = getattr(ctx.attr, "exports", []),
        runtime_deps = getattr(ctx.attr, "runtime_deps", []),
    )

    outputs = struct(
        jar = ctx.outputs.jar,
        srcjar = ctx.outputs.srcjar,
    )

    # Setup the compile action.
    return _kt_jvm_produce_output_jar_actions(
        ctx,
        rule_kind = rule_kind,
        compile_deps = compile_deps,
        outputs = outputs,
        extra_resources = extra_resources,
    )

def _kt_jvm_produce_output_jar_actions(
        ctx,
        rule_kind,
        compile_deps,
        outputs,
        extra_resources = {}):
    """This macro sets up a compile action for a Kotlin jar.

    Args:
        ctx: Invoking rule ctx, used for attr, actions, and label.
        rule_kind: The rule kind --e.g., `kt_jvm_library`.
        compile_deps: The old compile_deps struct (still used for compatibility).
        outputs: Output files struct with jar and srcjar fields.
        extra_resources: Extra resource files to include.

    Returns:
        A struct containing the providers JavaInfo (`java`) and `kt` (KtJvmInfo). This struct is not intended to be
        used as a legacy provider -- rather the caller should transform the result.
    """

    # Create compilation context from ctx
    compilation_ctx = _create_compilation_context_from_ctx(ctx, extra_resources)

    # Declare output files
    output_jar = outputs.jar
    output_source_jar = outputs.srcjar
    output_compile_jar = ctx.actions.declare_file(ctx.label.name + ".abi.jar")
    output_jdeps = None
    if compilation_ctx.kt_toolchain.jvm_emit_jdeps:
        output_jdeps = ctx.actions.declare_file(ctx.label.name + ".jdeps")

    # Call refactored compilation function
    compile_result = _run_kt_java_builder_actions(
        ctx = ctx,
        compilation_ctx = compilation_ctx,
        rule_kind = rule_kind,
        output = output_jar,
        output_source_jar = output_source_jar,
        output_compile_jar = output_compile_jar,
        jdeps = output_jdeps,
    )

    # Extract results
    java_info = compile_result.java_info
    annotation_processing = compile_result.annotation_processing
    generated_src_jars = []
    if compile_result.generated_source_jar:
        generated_src_jars.append(compile_result.generated_source_jar)
    all_output_jars = compile_result.output_jars

    instrumented_files = coverage_common.instrumented_files_info(
        ctx,
        source_attributes = ["srcs"],
        dependency_attributes = ["associates", "deps", "exports", "runtime_deps", "data"],
        extensions = ["kt", "java"],
    )

    return struct(
        java = java_info,
        instrumented_files = instrumented_files,
        kt = _KtJvmInfo(
            srcs = ctx.files.srcs,
            module_name = compilation_ctx.module_name,
            module_jars = compilation_ctx.compile_deps.associate_jars,
            language_version = compilation_ctx.kt_toolchain.api_version,
            exported_compiler_plugins = _collect_plugins_for_export(
                getattr(ctx.attr, "exported_compiler_plugins", []),
                getattr(ctx.attr, "exports", []),
            ),
            # intellij aspect needs this.
            outputs = struct(
                jdeps = output_jdeps,
                jars = [struct(
                    class_jar = output_jar,
                    ijar = output_compile_jar,
                    source_jars = [output_source_jar],
                )],
            ),
            transitive_compile_time_jars = java_info.transitive_compile_time_jars,
            transitive_source_jars = java_info.transitive_source_jars,
            annotation_processing = annotation_processing,
            additional_generated_source_jars = generated_src_jars,
            all_output_jars = all_output_jars,
        ),
    )

def _run_kt_java_builder_actions(
        ctx,
        compilation_ctx,
        rule_kind,
        output,
        output_source_jar,
        output_compile_jar,
        jdeps):
    """Runs the necessary KotlinBuilder and JavaBuilder actions to compile a jar.

    Args:
        ctx: Rule context.
        compilation_ctx: Compilation context struct.
        rule_kind: The rule kind (e.g., "kt_jvm_library").
        output: The final runtime jar output file.
        output_source_jar: The source jar output file.
        output_compile_jar: The ABI jar output file.
        jdeps: The jdeps output file (or None).

    Returns:
        JavaInfo provider with all compilation outputs.
    """
    compile_jars = []
    output_jars = []
    kt_stubs_for_java = []
    has_kt_sources = compilation_ctx.kt_source_files or compilation_ctx.source_jars

    generated_kapt_src_jars = []
    generated_ksp_src_jars = []

    # Run KAPT
    if has_kt_sources and compilation_ctx.annotation_processors:
        kapt_outputs = _run_kapt_builder_actions(
            ctx,
            compilation_ctx = compilation_ctx,
            rule_kind = rule_kind,
        )
        generated_kapt_src_jars.append(kapt_outputs.ap_generated_src_jar)
        output_jars.append(kapt_outputs.kapt_generated_class_jar)
        kt_stubs_for_java.append(
            JavaInfo(
                compile_jar = kapt_outputs.kapt_generated_stub_jar,
                output_jar = kapt_outputs.kapt_generated_stub_jar,
                neverlink = True,
            ),
        )

    # Run KSP
    ksp_generated_class_jar = None
    ksp_generated_src_jar = None
    if has_kt_sources and compilation_ctx.ksp_annotation_processors:
        ksp_outputs = _run_ksp_builder_actions(
            ctx,
            compilation_ctx = compilation_ctx,
        )
        ksp_generated_class_jar = ksp_outputs.ksp_generated_class_jar
        output_jars.append(ksp_generated_class_jar)
        ksp_generated_src_jar = ksp_outputs.ksp_generated_src_jar
        generated_ksp_src_jars.append(ksp_generated_src_jar)

    java_infos = []

    # Build Kotlin
    if has_kt_sources:
        kt_runtime_jar = ctx.actions.declare_file(ctx.label.name + "-kt.jar")
        if not "kt_abi_plugin_incompatible" in compilation_ctx.tags and compilation_ctx.kt_toolchain.experimental_use_abi_jars == True:
            kt_compile_jar = ctx.actions.declare_file(ctx.label.name + "-kt.abi.jar")
            outputs = {
                "abi_jar": kt_compile_jar,
                "output": kt_runtime_jar,
            }
        else:
            kt_compile_jar = kt_runtime_jar
            outputs = {
                "output": kt_runtime_jar,
            }

        kt_jdeps = None
        if compilation_ctx.kt_toolchain.jvm_emit_jdeps:
            kt_jdeps = ctx.actions.declare_file(ctx.label.name + "-kt.jdeps")
            outputs["kotlin_output_jdeps"] = kt_jdeps

        _run_kt_builder_action(
            ctx = ctx,
            compilation_ctx = compilation_ctx,
            rule_kind = rule_kind,
            mnemonic = "KotlinCompile",
            outputs = outputs,
            generated_src_jars = generated_kapt_src_jars + generated_ksp_src_jars,
            annotation_processors = [],
            build_kotlin = True,
        )

        compile_jars.append(kt_compile_jar)
        output_jars.append(kt_runtime_jar)
        if not compilation_ctx.annotation_processors or not compilation_ctx.kt_source_files:
            kt_stubs_for_java.append(JavaInfo(compile_jar = kt_compile_jar, output_jar = kt_runtime_jar, neverlink = True))

        kt_java_info = JavaInfo(
            output_jar = kt_runtime_jar,
            compile_jar = kt_compile_jar,
            jdeps = kt_jdeps,
            deps = compilation_ctx.compile_deps.deps,
            runtime_deps = _java_infos(compilation_ctx.runtime_deps),
            exports = _java_infos(compilation_ctx.exports),
            neverlink = compilation_ctx.neverlink,
        )
        java_infos.append(kt_java_info)

    # Build Java
    # If there is Java source or KAPT/KSP generated Java source compile that Java and fold it into
    # the final ABI jar. Otherwise just use the KT ABI jar as final ABI jar.
    ksp_generated_java_src_jars = generated_ksp_src_jars and is_ksp_processor_generating_java(compilation_ctx.plugin_info.plugins)
    if compilation_ctx.java_source_files or generated_kapt_src_jars or compilation_ctx.source_jars or ksp_generated_java_src_jars:
        javac_opts = javac_options_to_flags(compilation_ctx.javac_opts)
        javac_opts.extend([
            flag
            for plugin in compilation_ctx.plugin_info.plugins
            if JavacOptions in plugin
            for flag in javac_options_to_flags(plugin[JavacOptions])
        ])

        # Kotlin takes care of annotation processing. Note that JavaBuilder "discovers"
        # annotation processors in `deps` also.
        if len(compilation_ctx.kt_source_files) > 0:
            javac_opts.append("-proc:none")
        java_info = java_common.compile(
            ctx,
            source_files = compilation_ctx.java_source_files,
            source_jars = generated_kapt_src_jars + compilation_ctx.source_jars + generated_ksp_src_jars,
            output = ctx.actions.declare_file(ctx.label.name + "-java.jar"),
            deps = compilation_ctx.compile_deps.deps + kt_stubs_for_java + [p[JavaInfo] for p in compilation_ctx.plugin_info.plugins if JavaInfo in p],
            java_toolchain = compilation_ctx.java_toolchain,
            plugins = _plugin_mappers.targets_to_annotation_processors_java_plugin_info(compilation_ctx.plugin_info.plugins),
            javac_opts = javac_opts,
            neverlink = compilation_ctx.neverlink,
            strict_deps = compilation_ctx.kt_toolchain.experimental_strict_kotlin_deps,
        )
        ap_generated_src_jar = java_info.annotation_processing.source_jar
        java_outputs = java_info.java_outputs if hasattr(java_info, "java_outputs") else java_info.outputs.jars
        compile_jars = compile_jars + [
            jars.ijar
            for jars in java_outputs
        ]
        output_jars = output_jars + [
            jars.class_jar
            for jars in java_outputs
        ]
        java_infos.append(java_info)

    # Merge ABI jars into final compile jar.
    _fold_jars_action(
        ctx,
        rule_kind = rule_kind,
        toolchains = struct(java = compilation_ctx.java_toolchain),
        output_jar = output_compile_jar,
        action_type = "Abi",
        input_jars = compile_jars,
    )

    # Merge resource jars into output jars
    output_jars.extend(compilation_ctx.resource_jars)

    # Merge outputs into final runtime jar.
    _fold_jars_action(
        ctx,
        rule_kind = rule_kind,
        toolchains = struct(java = compilation_ctx.java_toolchain),
        output_jar = output,
        action_type = "Runtime",
        input_jars = output_jars,
    )

    # Create source jar
    source_jar = java_common.pack_sources(
        ctx.actions,
        output_source_jar = output_source_jar,
        sources = compilation_ctx.kt_source_files + compilation_ctx.java_source_files,
        source_jars = compilation_ctx.source_jars + generated_kapt_src_jars + generated_ksp_src_jars,
        java_toolchain = compilation_ctx.java_toolchain,
    )

    # Handle generated source jar (for annotation processing)
    generated_source_jar = None
    generated_src_jars = generated_kapt_src_jars + generated_ksp_src_jars
    if generated_src_jars:
        generated_source_jar = java_common.pack_sources(
            ctx.actions,
            output_source_jar = ctx.actions.declare_file(ctx.label.name + "-gensrc.jar"),
            source_jars = generated_src_jars,
            java_toolchain = compilation_ctx.java_toolchain,
        )

    # Handle jdeps
    if jdeps:
        jdeps_list = []
        for java_info in java_infos:
            if java_info.outputs.jdeps:
                jdeps_list.append(java_info.outputs.jdeps)

        if jdeps_list:
            _run_merge_jdeps_action(
                ctx = ctx,
                toolchains = struct(kt = compilation_ctx.kt_toolchain),
                jdeps = jdeps_list,
                deps = compilation_ctx.compile_deps.deps,
                outputs = {"output": jdeps},
            )
        else:
            ctx.actions.symlink(
                output = jdeps,
                target_file = compilation_ctx.kt_toolchain.empty_jdeps,
            )

    # Create annotation_processing struct if needed
    generated_class_jar = None
    if compilation_ctx.annotation_processors or compilation_ctx.ksp_annotation_processors:
        is_ksp = (compilation_ctx.ksp_annotation_processors != None)
        processor = compilation_ctx.ksp_annotation_processors if is_ksp else compilation_ctx.annotation_processors
        gen_jar = ksp_generated_src_jar if is_ksp else ap_generated_src_jar
        outputs_list = [java_info.outputs for java_info in java_infos]
        annotation_processing = _create_annotation_processing(
            annotation_processors = processor,
            ap_class_jar = [jars.class_jar for outputs in outputs_list for jars in outputs.jars][0],
            ap_source_jar = gen_jar,
        )
        generated_class_jar = annotation_processing.class_jar if annotation_processing else None
    else:
        annotation_processing = None

    # Return struct with JavaInfo and annotation processing info
    # Note: We can't include annotation_processing in JavaInfo constructor,
    # so we return it as a separate field in a struct
    java_info_result = JavaInfo(
        output_jar = output,
        compile_jar = output_compile_jar,
        source_jar = source_jar,
        jdeps = jdeps,
        deps = compilation_ctx.compile_deps.deps,
        runtime_deps = _java_infos(compilation_ctx.runtime_deps),
        exports = _java_infos(compilation_ctx.exports),
        neverlink = compilation_ctx.neverlink,
        generated_source_jar = generated_source_jar,
        generated_class_jar = generated_class_jar,
    )

    # Return struct with JavaInfo and additional metadata
    return struct(
        java_info = java_info_result,
        annotation_processing = annotation_processing,
        generated_source_jar = generated_source_jar,
        generated_class_jar = generated_class_jar,
        output_jars = output_jars,  # All jars that were merged into the runtime jar
    )

def _create_annotation_processing(annotation_processors, ap_class_jar, ap_source_jar):
    """Creates the annotation_processing field for Kt to match what JavaInfo

    The Bazel Plugin IDE logic is based on this assumption in order to locate the Annotation
    Processor generated source code.

    See https://docs.bazel.build/versions/master/skylark/lib/JavaInfo.html#annotation_processing
    """
    if annotation_processors:
        return struct(
            enabled = True,
            class_jar = ap_class_jar,
            source_jar = ap_source_jar,
        )
    return None

def _export_only_providers(ctx, actions, attr, outputs):
    """_export_only_providers creates a series of forwarding providers without compilation overhead.

    Args:
        ctx: kt_compiler_ctx
        actions: invoking rule actions,
        attr: kt_compiler_attributes,
        outputs: kt_compiler_outputs

    Returns:
        kt_compiler_result
    """
    toolchains = _compiler_toolchains(ctx)

    # satisfy the outputs requirement. should never execute during normal compilation.
    actions.symlink(
        output = outputs.jar,
        target_file = toolchains.kt.empty_jar,
    )

    actions.symlink(
        output = outputs.srcjar,
        target_file = toolchains.kt.empty_jar,
    )

    output_jdeps = None
    if toolchains.kt.jvm_emit_jdeps:
        output_jdeps = ctx.actions.declare_file(ctx.label.name + ".jdeps")
        actions.symlink(
            output = output_jdeps,
            target_file = toolchains.kt.empty_jdeps,
        )

    java = JavaInfo(
        output_jar = toolchains.kt.empty_jar,
        compile_jar = toolchains.kt.empty_jar,
        deps = _java_infos(attr.deps),
        exports = _java_infos(getattr(attr, "exports", [])),
        neverlink = getattr(attr, "neverlink", False),
        jdeps = output_jdeps,
    )

    return struct(
        java = java,
        kt = _KtJvmInfo(
            module_name = _utils.derive_module_name(ctx.label, getattr(ctx.attr, "module_name", "")),
            module_jars = [],
            language_version = toolchains.kt.api_version,
            exported_compiler_plugins = _collect_plugins_for_export(
                getattr(attr, "exported_compiler_plugins", []),
                getattr(attr, "exports", []),
            ),
        ),
        instrumented_files = coverage_common.instrumented_files_info(
            ctx,
            source_attributes = ["srcs"],
            dependency_attributes = ["associates", "deps", "exports", "runtime_deps", "data"],
            extensions = ["kt", "java"],
        ),
    )

compile = struct(
    compiler_toolchains = _compiler_toolchains,
    verify_associates_not_duplicated_in_deps = _fail_if_invalid_associate_deps,
    export_only_providers = _export_only_providers,
    kt_jvm_produce_output_jar_actions = _kt_jvm_produce_output_jar_actions,
    kt_jvm_produce_jar_actions = _kt_jvm_produce_jar_actions,
)

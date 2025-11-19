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

def _deps_artifacts(kt_toolchain, targets):
    """Collect Jdeps artifacts if required."""
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
def _fold_jars_action(ctx, rule_kind, java_toolchain, output_jar, input_jars, action_type = ""):
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
        executable = java_toolchain.single_jar,
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

def _run_merge_jdeps_action(ctx, kt_toolchain, jdeps, outputs, deps, additional_deps, ):
    """Creates a Jdeps merger action invocation."""
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("--flagfile=%s", use_always = True)

    args.add("--target_label", ctx.label)

    for f, path in outputs.items():
        args.add("--" + f, path)

    args.add_all("--inputs", jdeps, omit_if_empty = True)
    args.add("--report_unused_deps", kt_toolchain.experimental_report_unused_deps)

    mnemonic = "JdepsMerge"
    progress_message = "%s %%{label} { jdeps: %d }" % (
        mnemonic,
        len(jdeps),
    )

    inputs = depset(jdeps)
    if not kt_toolchain.experimental_report_unused_deps == "off":
        # For sandboxing to work, and for this action to be deterministic, the compile jars need to be passed as inputs
        inputs = depset(jdeps, transitive = [
            depset([], transitive = [dep.transitive_compile_time_jars for dep in _java_infos(deps) + additional_deps]),
        ])

    ctx.actions.run(
        mnemonic = mnemonic,
        inputs = inputs,
        tools = [kt_toolchain.jdeps_merger.files_to_run, kt_toolchain.jvm_stdlibs.compile_jars],
        outputs = [f for f in outputs.values()],
        executable = kt_toolchain.jdeps_merger.files_to_run.executable,
        execution_requirements = kt_toolchain.execution_requirements,
        arguments = [
            ctx.actions.args().add_all(kt_toolchain.builder_args),
            args,
        ],
        progress_message = progress_message,
        toolchain = _TOOLCHAIN_TYPE,
    )

def _run_kapt_builder_actions(
        ctx,
        kt_toolchain,
        java_runtime,
        kotlinc_opts,
        javac_opts,
        source_jars,
        kt_source_files,
        java_source_files,
        plugins,
        deps,
        additional_deps,
        associates,
        module_name,
        tags,
        rule_kind,
        annotation_processors,
        generated_java_srcjar,
        generated_class_jar,
        generated_stub_jar):
    """Runs KAPT using the KotlinBuilder tool."""
    _run_kt_builder_action(
        ctx,
        kt_toolchain = kt_toolchain,
        java_runtime = java_runtime,
        kotlinc_opts = kotlinc_opts,
        javac_opts = javac_opts,
        source_jars = source_jars,
        kt_source_files = kt_source_files,
        java_source_files = java_source_files,
        plugins = plugins,
        deps = deps,
        additional_deps = additional_deps,
        associates = associates,
        module_name = module_name,
        tags = tags,
        rule_kind = rule_kind,
        annotation_processors = annotation_processors,
        outputs = {
            "generated_java_srcjar": generated_java_srcjar,
            "kapt_generated_class_jar": generated_class_jar,
            "kapt_generated_stub_jar": generated_stub_jar,
        },
        build_kotlin = False,
        mnemonic = "KotlinKapt",
    )

def _run_ksp_builder_actions(
        ctx,
        kt_toolchain,
        java_runtime,
        kotlinc_opts,
        javac_opts,
        source_jars,
        kt_source_files,
        java_source_files,
        plugins,
        deps,
        additional_deps,
        associates,
        module_name,
        tags,
        rule_kind,
        annotation_processors,
        generated_java_srcjar,
        generated_class_jar):
    """Runs KSP using the KotlinBuilder tool."""
    _run_kt_builder_action(
        ctx,
        kt_toolchain = kt_toolchain,
        java_runtime = java_runtime,
        kotlinc_opts = kotlinc_opts,
        javac_opts = javac_opts,
        source_jars = source_jars,
        kt_source_files = kt_source_files,
        java_source_files = java_source_files,
        plugins = plugins,
        deps = deps,
        additional_deps = additional_deps,
        associates = associates,
        module_name = module_name,
        tags = tags,
        rule_kind = rule_kind,
        annotation_processors = annotation_processors,
        outputs = {
            "ksp_generated_classes_jar": generated_class_jar,
            "ksp_generated_java_srcjar": generated_java_srcjar,
        },
        build_kotlin = False,
        mnemonic = "KotlinKsp",
    )

def _java_infos(target_list):
    return [target[JavaInfo] for target in target_list if JavaInfo in target]

# copied from kotlin/internal/jvm/jvm_deps.bzl
def _classpath(kt_toolchain, deps, additional_deps, associates, tags):
    dep_infos = (
        additional_deps +
        _java_infos(deps) +
        _java_infos(associates.deps)
    )

    # Reduced classpath, exclude transitive deps from compilation
    if kt_toolchain.experimental_prune_transitive_deps and not "kt_experimental_prune_transitive_deps_incompatible" in tags:
        transitive = [
            d.compile_jars
            for d in dep_infos
        ]
    else:
        transitive = [
            d.compile_jars
            for d in dep_infos
        ] + [
            d.transitive_compile_time_jars
            for d in dep_infos
        ]

    compile_depset_list = depset(transitive = transitive + [associates.jars]).to_list()
    compile_depset_list_filtered = [jar for jar in compile_depset_list if not _sets.contains(associates.abi_jar_set, jar)]

    return depset(compile_depset_list_filtered)

def _run_kt_builder_action(
        ctx,
        kt_toolchain,
        java_runtime,
        kotlinc_opts,
        javac_opts,
        source_jars,
        kt_source_files,
        java_source_files,
        plugins,
        deps,
        additional_deps,
        associates,
        module_name,
        tags,
        rule_kind,
        mnemonic,
        outputs,
        annotation_processors,
        build_kotlin):
    """Creates a KotlinBuilder action invocation.

    Args:
        *: See kt_jvm_common.compile for documentation of the other arguments.
        associates: (struct from kotlin/internal/jvm/associates.bzl) Not sutiable for public API.
            Mandatory.
        rule_kind: (String) The current rule kind. Must start with `kt_jvm_`. Mandatory.
        mnemonic: (String) The mnemonic of the action. Mandatory.
        outputs: (dict[String, File]) Dictionary of action specific ouptus. Mandatory.
        annotation_processors: ([Target]) List of annotation processors to run. Optional.
        build_kotlin: (bool) Whether to run an actual build. Only valid if no annotation processors
            are set. Mandatory.
    """
    if not mnemonic:
        fail("Error: A `mnemonic` must be provided for every invocation of `_run_kt_builder_action`!")

    if build_kotlin and annotation_processors:
        fail("Error: The `_run_kt_builder_action` should either be called to build or to process annotations~")

    classpath = _classpath(
        kt_toolchain,
        deps,
        additional_deps,
        associates,
        tags,
    )

    deps_artifacts = _deps_artifacts(kt_toolchain, deps + associates.deps)

    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.use_param_file("--flagfile=%s", use_always = True)

    args.add("--target_label", ctx.label)
    args.add("--rule_kind", rule_kind)
    args.add("--kotlin_module_name", module_name)

    kotlin_jvm_target = kotlinc_opts.jvm_target if (kotlinc_opts and kotlinc_opts.jvm_target) else kt_toolchain.jvm_target
    args.add("--kotlin_jvm_target", kotlin_jvm_target)
    args.add("--kotlin_api_version", kt_toolchain.api_version)
    args.add("--kotlin_language_version", kt_toolchain.language_version)

    debug = kt_toolchain.debug
    for tag in tags:
        if tag == "trace":
            debug = debug + [tag]
        if tag == "timings":
            debug = debug + [tag]
    args.add_all("--kotlin_debug_tags", debug, omit_if_empty = False)

    for f, path in outputs.items():
        args.add("--" + f, path)

    # Unwrap kotlinc_options/javac_options options or default to the ones being provided by the toolchain
    args.add_all("--kotlin_passthrough_flags", kotlinc_options_to_flags(kotlinc_opts))
    args.add_all("--javacopts", javac_opts)
    args.add_all("--direct_dependencies", _java_infos_to_compile_jars(_java_infos(deps) + additional_deps))
    args.add("--strict_kotlin_deps", kt_toolchain.experimental_strict_kotlin_deps)
    args.add_all("--classpath", classpath)
    args.add("--reduced_classpath_mode", kt_toolchain.experimental_reduce_classpath_mode)
    args.add("--build_tools_api", kt_toolchain.experimental_build_tools_api)
    args.add_all("--sources", kt_source_files + java_source_files, omit_if_empty = True)
    args.add_all("--source_jars", source_jars, omit_if_empty = True)
    args.add_all("--deps_artifacts", deps_artifacts, omit_if_empty = True)
    args.add_all("--kotlin_friend_paths", associates.jars, omit_if_empty = True)
    args.add("--instrument_coverage", ctx.coverage_instrumented())

    # semantic cahnge from: _new_plugins_from(ctx.attr.plugins + _exported_plugins(deps = ctx.attr.deps))
    plugin_info = _new_plugins_from(plugins + _exported_plugins(deps))

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
        plugin_info.stubs_phase.classpath,
        omit_if_empty = True,
    )

    args.add_all(
        "--stubs_plugin_options",
        plugin_info.stubs_phase.options,
        map_each = _format_compile_plugin_options,
        omit_if_empty = True,
    )

    args.add_all(
        "--compiler_plugin_classpath",
        plugin_info.compile_phase.classpath,
        omit_if_empty = True,
    )

    args.add_all(
        "--compiler_plugin_options",
        plugin_info.compile_phase.options,
        map_each = _format_compile_plugin_options,
        omit_if_empty = True,
    )

    if not "kt_remove_private_classes_in_abi_plugin_incompatible" in tags and kt_toolchain.experimental_remove_private_classes_in_abi_jars == True:
        args.add("--remove_private_classes_in_abi_jar", "true")

    if not "kt_treat_internal_as_private_in_abi_plugin_incompatible" in tags and kt_toolchain.experimental_treat_internal_as_private_in_abi_jars == True:
        if not "kt_remove_private_classes_in_abi_plugin_incompatible" in tags and kt_toolchain.experimental_remove_private_classes_in_abi_jars == True:
            args.add("--treat_internal_as_private_in_abi_jar", "true")
        else:
            fail(
                "experimental_treat_internal_as_private_in_abi_jars without experimental_remove_private_classes_in_abi_jars is invalid." +
                "\nTo remove internal symbols from kotlin abi jars ensure experimental_remove_private_classes_in_abi_jars " +
                "and experimental_treat_internal_as_private_in_abi_jars are both enabled in define_kt_toolchain." +
                "\nAdditionally ensure the target does not contain the kt_remove_private_classes_in_abi_plugin_incompatible tag.",
            )

    if not "kt_remove_debug_info_in_abi_plugin_incompatible" in tags and kt_toolchain.experimental_remove_debug_info_in_abi_jars == True:
        args.add("--remove_debug_info_in_abi_jar", "true")

    args.add("--build_kotlin", build_kotlin)

    progress_message = "%s %%{label} { kt: %d, java: %d, srcjars: %d } for %s" % (
        mnemonic,
        len(kt_source_files),
        len(java_source_files),
        len(source_jars),
        ctx.var.get("TARGET_CPU", "UNKNOWN CPU"),
    )

    # samntic change from: _plugin_mappers.targets_to_transitive_runtime_jars(ctx.attr.plugins + ctx.attr.deps)
    transitive_runtime_jars = _plugin_mappers.targets_to_transitive_runtime_jars(plugins + deps)

    ctx.actions.run(
        mnemonic = mnemonic,
        inputs = depset(
            kt_source_files + java_source_files + source_jars,
            transitive = [
                classpath,
                associates.jars,
                transitive_runtime_jars,
                deps_artifacts,
                plugin_info.stubs_phase.classpath,
                plugin_info.compile_phase.classpath,
            ],
        ),
        tools = [
            kt_toolchain.kotlinbuilder.files_to_run,
            kt_toolchain.kotlin_home.files_to_run,
        ],
        outputs = [f for f in outputs.values()],
        executable = kt_toolchain.kotlinbuilder.files_to_run.executable,
        execution_requirements = _utils.add_dicts(
            kt_toolchain.execution_requirements,
            {"worker-key-mnemonic": mnemonic},
        ),
        arguments = [ctx.actions.args().add_all(kt_toolchain.builder_args), args],
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
        compile_deps: The rule kind --e.g., `kt_jvm_library`.
    Returns:
        A struct containing the providers JavaInfo (`java`) and `kt` (KtJvmInfo). This struct is not intended to be
        used as a legacy provider -- rather the caller should transform the result.
    """
    extra_resource_jars = []

    # If this rule has any resources declared setup a zipper action to turn them into a jar.
    if len(ctx.files.resources) + len(extra_resources) > 0:
        extra_resource_jars.append(_build_resourcejar_action(ctx, extra_resources))

    kt_toolchain = ctx.toolchains[_TOOLCHAIN_TYPE]

    compile_jar = ctx.actions.declare_file(ctx.label.name + ".abi.jar")
    output_jdeps = None
    if kt_toolchain.jvm_emit_jdeps:
        output_jdeps = ctx.actions.declare_file(ctx.label.name + ".jdeps")

    partitioned_srcs = _partitioned_srcs(ctx.files.srcs)

    java_info = _run_kt_java_builder_actions(
        ctx,
        rule_kind = rule_kind,
        output = outputs.jar,
        output_source_jar = outputs.srcjar,
        output_compile_jar = compile_jar,
        kt_toolchain = kt_toolchain,
        java_toolchain = find_java_toolchain(ctx, ctx.attr._java_toolchain),
        java_runtime = find_java_runtime_toolchain(ctx, ctx.attr._host_javabase),
        kotlinc_opts = ctx.attr.kotlinc_opts[KotlincOptions] if ctx.attr.kotlinc_opts else kt_toolchain.kotlinc_options,
        javac_opts = javac_options_to_flags(ctx.attr.javac_opts[JavacOptions] if ctx.attr.javac_opts else kt_toolchain.javac_options),
        source_jars = partitioned_srcs.src_jars,
        resource_jars = ctx.files.resource_jars + extra_resource_jars,
        kt_source_files = partitioned_srcs.kt,
        java_source_files = partitioned_srcs.java,
        plugins = ctx.attr.plugins,
        deps = ctx.attr.deps + ctx.attr.associates,
        additional_deps = compile_deps.additional_deps + [kt_toolchain.jvm_stdlibs],  # TODO: add dedicated api for stdlibs
        runtime_deps = compile_deps.runtime_deps,
        associates = compile_deps.associates,
        exports = compile_deps.exports,
        neverlink = getattr(ctx.attr, "neverlink", False),
        module_name = compile_deps.module_name,
        tags = ctx.attr.tags,
        jdeps = output_jdeps,
    )

    annotation_processors = _plugin_mappers.targets_to_annotation_processors(ctx.attr.plugins + ctx.attr.deps)
    ksp_annotation_processors = _plugin_mappers.targets_to_ksp_annotation_processors(ctx.attr.plugins + ctx.attr.deps)

    annotation_processing = None
    if annotation_processors or ksp_annotation_processors:
        annotation_processing = _create_annotation_processing(
            annotation_processors = annotation_processors or ksp_annotation_processors,
            ap_class_jar = java_info.annotation_processing.class_jar,
            ap_source_jar = java_info.annotation_processing.source_jar,
        )

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
            module_name = compile_deps.module_name,
            module_jars = compile_deps.associates.jars,
            language_version = kt_toolchain.api_version,
            exported_compiler_plugins = _collect_plugins_for_export(
                getattr(ctx.attr, "exported_compiler_plugins", []),
                getattr(ctx.attr, "exports", []),
            ),
            # intellij aspect needs this.
            outputs = struct(
                jdeps = output_jdeps,
                jars = [struct(
                    class_jar = outputs.jar,
                    ijar = compile_jar,
                    source_jars = java_info.source_jars,
                )],
            ),
            transitive_compile_time_jars = java_info.transitive_compile_time_jars,
            transitive_source_jars = java_info.transitive_source_jars,
            annotation_processing = annotation_processing,
            # additional_generated_source_jars = generated_src_jars, ?
            all_output_jars = [jars.class_jar for jars in java_info.java_outputs],
        ),
    )

def _run_kt_java_builder_actions(
        ctx,
        rule_kind,
        output,
        output_source_jar,
        output_compile_jar,
        kt_toolchain,
        java_toolchain,
        java_runtime,
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
        module_name,
        tags,
        jdeps):
    """Compiles Kotlin/Java source files/jars from the implementation of INTERNAL Starlark rules.

    Might generated additional files for general processing. Filenames are derived from the name
    of the output jar.

    Args:
        *: See kt_jvm_common.compile for documentation of the other arguments.
        associates: (struct from kotlin/internal/jvm/associates.bzl) Not sutiable for public API.
            Mandatory.
        kotlinc_opts: ([KotlincOptions]) Not sutibale for public API. Optional.
        rule_kind: (String) The current rule kind. Must start with `kt_jvm_`. Mandatory.

    Returns:
        (JavaInfo)
    """
    base_name = output.basename.removesuffix(".jar")

    annotation_processors = _plugin_mappers.targets_to_annotation_processors(plugins + deps)
    ksp_annotation_processors = _plugin_mappers.targets_to_ksp_annotation_processors(plugins + deps)

    compile_jars = []
    output_jars = []
    kt_stubs_for_java = []
    generated_kapt_src_jars = []
    generated_ksp_src_jars = []
    has_kt_sources = kt_source_files or source_jars

    # Run KAPT
    if has_kt_sources and annotation_processors:
        kapt_generated_src_jar = ctx.actions.declare_file(base_name + "-kapt-gensrc.jar")
        kapt_generated_stub_jar = ctx.actions.declare_file(base_name + "-kapt-generated-stub.jar")
        kapt_generated_class_jar = ctx.actions.declare_file(base_name + "-kapt-generated-class.jar")
        _run_kapt_builder_actions(
            ctx,
            kt_toolchain = kt_toolchain,
            java_runtime = java_runtime,
            kotlinc_opts = kotlinc_opts,
            javac_opts = javac_opts,
            source_jars = source_jars,
            kt_source_files = kt_source_files,
            java_source_files = java_source_files,
            plugins = plugins,
            deps = deps,
            additional_deps = additional_deps,
            associates = associates,
            module_name = module_name,
            tags = tags,
            rule_kind = rule_kind,
            annotation_processors = annotation_processors,
            generated_java_srcjar = kapt_generated_src_jar,
            generated_stub_jar = kapt_generated_stub_jar,
            generated_class_jar = kapt_generated_class_jar,
        )
        generated_kapt_src_jars.append(kapt_generated_src_jar)
        output_jars.append(kapt_generated_class_jar)
        kt_stubs_for_java.append(
            JavaInfo(
                compile_jar = kapt_generated_stub_jar,
                output_jar = kapt_generated_stub_jar,
                neverlink = True,
            ),
        )

    # Run KSP
    ksp_generated_class_jar = None
    ksp_generated_src_jar = None
    if has_kt_sources and ksp_annotation_processors:
        ksp_generated_src_jar = ctx.actions.declare_file(base_name + "-ksp-kt-gensrc.jar")
        ksp_generated_class_jar = ctx.actions.declare_file(base_name + "-ksp-kt-genclasses.jar")
        _run_ksp_builder_actions(
            ctx,
            kt_toolchain = kt_toolchain,
            java_runtime = java_runtime,
            kotlinc_opts = kotlinc_opts,
            javac_opts = javac_opts,
            source_jars = source_jars,
            kt_source_files = kt_source_files,
            java_source_files = java_source_files,
            plugins = plugins,
            deps = deps,
            additional_deps = additional_deps,
            associates = associates,
            module_name = module_name,
            tags = tags,
            rule_kind = rule_kind,
            annotation_processors = ksp_annotation_processors,
            generated_java_srcjar = ksp_generated_src_jar,
            generated_class_jar = ksp_generated_class_jar,
        )
        output_jars.append(ksp_generated_class_jar)
        generated_ksp_src_jars.append(ksp_generated_src_jar)

    java_infos = []

    # Build Kotlin
    if has_kt_sources:
        kt_runtime_jar = ctx.actions.declare_file(base_name + "-kt.jar")
        if not "kt_abi_plugin_incompatible" in tags and kt_toolchain.experimental_use_abi_jars == True:
            kt_compile_jar = ctx.actions.declare_file(base_name + "-kt.abi.jar")
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
        if kt_toolchain.jvm_emit_jdeps:
            kt_jdeps = ctx.actions.declare_file(base_name + "-kt.jdeps")
            outputs["kotlin_output_jdeps"] = kt_jdeps

        _run_kt_builder_action(
            ctx,
            kt_toolchain = kt_toolchain,
            java_runtime = java_runtime,
            kotlinc_opts = kotlinc_opts,
            javac_opts = javac_opts,
            source_jars = source_jars + generated_ksp_src_jars + generated_kapt_src_jars,
            kt_source_files = kt_source_files,
            java_source_files = java_source_files,
            plugins = plugins,
            deps = deps,
            additional_deps = additional_deps,
            associates = associates,
            module_name = module_name,
            tags = tags,
            rule_kind = rule_kind,
            outputs = outputs,
            annotation_processors = [],
            build_kotlin = True,
            mnemonic = "KotlinCompile",
        )

        compile_jars.append(kt_compile_jar)
        output_jars.append(kt_runtime_jar)
        if not annotation_processors or not kt_source_files:
            kt_stubs_for_java.append(JavaInfo(compile_jar = kt_compile_jar, output_jar = kt_runtime_jar, neverlink = True))

        kt_java_info = JavaInfo(
            output_jar = kt_runtime_jar,
            compile_jar = kt_compile_jar,
            jdeps = kt_jdeps,
            deps = _java_infos(deps) + additional_deps,
            runtime_deps = _java_infos(runtime_deps),
            exports = _java_infos(exports),
            neverlink = neverlink,
        )
        java_infos.append(kt_java_info)

    # Build Java
    # If there is Java source or KAPT/KSP generated Java source compile that Java and fold it into
    # the final ABI jar. Otherwise just use the KT ABI jar as final ABI jar.
    ksp_generated_java_src_jars = generated_ksp_src_jars and is_ksp_processor_generating_java(plugins)
    if java_source_files or generated_kapt_src_jars or source_jars or ksp_generated_java_src_jars:
        all_javac_opts = []
        all_javac_opts.extend(javac_opts)
        all_javac_opts.extend([
            flag
            for plugin in plugins
            if JavacOptions in plugin
            for flag in javac_options_to_flags(plugin[JavacOptions])
        ])

        # Kotlin takes care of annotation processing. Note that JavaBuilder "discovers"
        # annotation processors in `deps` also.
        if len(kt_source_files) > 0:
            all_javac_opts.append("-proc:none")

        java_info = java_common.compile(
            ctx,
            source_files = java_source_files,
            source_jars = generated_kapt_src_jars + source_jars + generated_ksp_src_jars,
            output = ctx.actions.declare_file(base_name + "-java.jar"),
            deps = kt_stubs_for_java + _java_infos(deps + plugins) + additional_deps,
            java_toolchain = java_toolchain,
            plugins = _plugin_mappers.targets_to_annotation_processors_java_plugin_info(plugins),
            javac_opts = all_javac_opts,
            neverlink = neverlink,
            strict_deps = kt_toolchain.experimental_strict_kotlin_deps,
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
        java_toolchain = java_toolchain,
        output_jar = output_compile_jar,
        action_type = "Abi",
        input_jars = compile_jars,
    )

    # Merge outputs into final runtime jar.
    _fold_jars_action(
        ctx,
        rule_kind = rule_kind,
        java_toolchain = java_toolchain,
        output_jar = output,
        action_type = "Runtime",
        input_jars = output_jars + resource_jars,
    )

    if kt_toolchain.jvm_emit_jdeps:
        all_jdeps = []
        for java_info in java_infos:
            if java_info.outputs.jdeps:
                all_jdeps.append(java_info.outputs.jdeps)

        if all_jdeps:
            _run_merge_jdeps_action(
                ctx,
                kt_toolchain = kt_toolchain,
                deps = deps,
                additional_deps = additional_deps,
                jdeps = all_jdeps,
                outputs = {"output": jdeps},
            )
        else:
            ctx.actions.symlink(
                output = jdeps,
                target_file = kt_toolchain.empty_jdeps,
            )

    output_source_jar = java_common.pack_sources(
        ctx.actions,
        output_source_jar = output_source_jar,
        sources = kt_source_files + java_source_files,
        source_jars = source_jars + generated_kapt_src_jars + generated_ksp_src_jars,
        java_toolchain = java_toolchain,
    )

    annotation_processing = None
    if annotation_processors or ksp_annotation_processors:
        is_ksp = (ksp_annotation_processors != None)
        processor = ksp_annotation_processors if is_ksp else annotation_processors
        gen_jar = ksp_generated_src_jar if is_ksp else ap_generated_src_jar
        outputs_list = [java_info.outputs for java_info in java_infos]
        annotation_processing = _create_annotation_processing(
            annotation_processors = processor,
            ap_class_jar = [jars.class_jar for outputs in outputs_list for jars in outputs.jars][0],
            ap_source_jar = gen_jar,
        )

    generated_source_jar = java_common.pack_sources(
        ctx.actions,
        output_source_jar = ctx.actions.declare_file(ctx.label.name + "-gensrc.jar"),
        source_jars = generated_kapt_src_jars + generated_ksp_src_jars,
        java_toolchain = java_toolchain,
    ) if generated_kapt_src_jars + generated_ksp_src_jars else None

    generated_class_jar = None
    if annotation_processing:
        generated_class_jar = annotation_processing.class_jar
    # generated_source_jar = None
    # generated_class_jar = None
    # if generated_kapt_src_jars or generated_ksp_src_jars:
    #     generated_source_jar = java_common.pack_sources(
    #         ctx.actions,
    #         output_source_jar = ctx.actions.declare_file(base_name + "-gensrc.jar"),
    #         source_jars = generated_kapt_src_jars + generated_ksp_src_jars,
    #         java_toolchain = java_toolchain,
    #     )

    #     # this seems a bity hacky
    #     generated_class_jar = [output.class_jar for info in java_infos for output in info.java_outputs][0]

    return JavaInfo(
        output_jar = output,
        compile_jar = output_compile_jar,
        source_jar = output_source_jar,
        jdeps = jdeps,
        deps = _java_infos(deps) + additional_deps,
        runtime_deps = _java_infos(runtime_deps),
        exports = _java_infos(exports),
        neverlink = neverlink,
        generated_source_jar = generated_source_jar,
        generated_class_jar = generated_class_jar,
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
        deps = [_java_info(d) for d in attr.deps],
        exports = [_java_info(d) for d in getattr(attr, "exports", [])],
        neverlink = getattr(attr, "neverlink", False),
        jdeps = output_jdeps,
    )

    return struct(
        java = java,
        kt = _KtJvmInfo(
            module_name = _utils.derive_module_name(ctx),
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
    run_compile_action = _run_kt_java_builder_actions,
)

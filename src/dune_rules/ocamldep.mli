(** ocamldep management *)

open Import

val deps_of
  :  sandbox:Sandbox_config.t
  -> modules:Modules.With_vlib.t
  -> sctx:Super_context.t
  -> dir:Path.Build.t
  -> obj_dir:Path.Build.t Obj_dir.t
  -> ml_kind:Ml_kind.t
  -> for_:Compilation_mode.t
  -> Module.t
  -> Module.t list Action_builder.t Memo.t

val read_deps_of
  :  obj_dir:Path.Build.t Obj_dir.t
  -> modules:Modules.With_vlib.t
  -> ml_kind:Ml_kind.t
  -> for_:Compilation_mode.t
  -> Module.t
  -> Module.t list Action_builder.t

(** [read_immediate_deps_of ~obj_dir ~modules ~ml_kind unit] returns the
    immediate dependencies found in the modules of [modules] for the file with
    kind [ml_kind] of the module [unit]. If there is no such file with kind
    [ml_kind], then an empty list of dependencies is returned. *)
val read_immediate_deps_of
  :  obj_dir:Path.Build.t Obj_dir.t
  -> modules:Modules.With_vlib.t
  -> ml_kind:Ml_kind.t
  -> for_:Compilation_mode.t
  -> Module.t
  -> Module.t list Action_builder.t

(** [read_immediate_deps_raw_of ~obj_dir ~ml_kind ~for_ unit] returns the raw
    module names from ocamldep output without filtering against the stanza's
    module set. This preserves cross-library references that
    [read_immediate_deps_of] discards. *)
val read_immediate_deps_raw_of
  :  obj_dir:Path.Build.t Obj_dir.t
  -> ml_kind:Ml_kind.t
  -> for_:Compilation_mode.t
  -> Module.t
  -> Module_name.Set.t Action_builder.t

(** [raw_deps_memo ~env ~ocamldep ~source ~ml_kind] runs [ocamldep -modules]
    on [source] as a memoised computation keyed on the source file's content
    digest. Returns the raw set of module names ocamldep emits, the same
    shape [read_immediate_deps_raw_of] currently reads from a [.d] file.
    Does not produce any build artefacts. *)
val raw_deps_memo
  :  env:Env.t
  -> ocamldep:Path.t
  -> source:Path.Outside_build_dir.t
  -> ml_kind:Ml_kind.t
  -> Module_name.Set.t Memo.t

(** [source_of_file file] recovers a [Path.Outside_build_dir.t] suitable for
    [Fs_memo.file_digest] from a [Module.File.t]. Paths already outside
    [_build/] pass through. Staged real sources (paths under
    [_build/<context>/]) are remapped to the source tree via
    [Path.Build.drop_build_context]. Returns [None] for paths with no
    source-tree counterpart — rule-generated files whose content is
    produced by an upstream build rule. *)
val source_of_file : Module.File.t -> Path.Outside_build_dir.t option

(** [immediate_deps_memo ~modules ~dir ~env ~ocamldep ~unit ~ml_kind] returns
    the intra-stanza modules that [unit]'s [ml_kind] source immediately
    references, augmented with [implicit_deps] to match the shape the
    build-rule [deps_of] path produces. Cross-library references are
    dropped, matching the semantics of [read_immediate_deps_of]. Returns
    only the implicit-deps contribution when [unit] has no source for
    [ml_kind], when the source is flagged [implicit] (dune-synthesised
    with statically-empty ocamldep output), or when the source's build
    path has no source-tree counterpart (the caller is expected to fall
    back to the build-rule path in that case). *)
val immediate_deps_memo
  :  modules:Modules.With_vlib.t
  -> dir:Path.Build.t
  -> env:Env.t
  -> ocamldep:Path.t
  -> unit:Module.t
  -> ml_kind:Ml_kind.t
  -> Module.t list Memo.t

(** [deps_of_memo ~modules ~dir ~env ~ocamldep ~ml_kind unit] returns the
    transitive intra-stanza dependencies of [unit] for [ml_kind], the same
    shape the existing [.all-deps] file produces (the module's closure
    excluding itself). Computed in-memory from [raw_deps_memo] results;
    emits no build rules. Cycles raise [User_error] with the same wording
    [Dep_graph.top_closed] uses for the build-rule path. Modules with
    generated sources (in [_build/]) contribute the empty immediate-dep
    set via [immediate_deps_memo]; callers that need the build-rule path
    for such modules must gate calls to this function. *)
val deps_of_memo
  :  modules:Modules.With_vlib.t
  -> dir:Path.Build.t
  -> env:Env.t
  -> ocamldep:Path.t
  -> ml_kind:Ml_kind.t
  -> Module.t
  -> Module.t list Memo.t

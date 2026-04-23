open Import
open Memo.O

module Merge_files_into = struct
  module Spec = struct
    type ('src, 'dst) t =
      { transitive : 'src list
      ; immediate : Module_name.Unique.t list
      ; target : 'dst
      }

    let name = "merge_files_into"
    let version = 2
    let is_useful_to ~memoize:_ = true

    let bimap t path target =
      { t with transitive = List.map t.transitive ~f:path; target = target t.target }
    ;;

    let encode
          (type src dst)
          ({ transitive; immediate; target } : (src, dst) t)
          (input : src -> Sexp.t)
          (output : dst -> Sexp.t)
      : Sexp.t
      =
      List
        [ List (List.map transitive ~f:input)
        ; List
            (List.map ~f:(fun s -> Sexp.Atom (Module_name.Unique.to_string s)) immediate)
        ; output target
        ]
    ;;

    let action { transitive; immediate; target } ~ectx:_ ~eenv:_ =
      Async.async (fun () ->
        List.fold_left
          transitive
          ~init:(Module_name.Unique.Set.of_list immediate)
          ~f:(fun set source_path ->
            Io.lines_of_file source_path
            |> Module_name.Unique.Set.of_list_map ~f:Module_name.Unique.of_string
            |> Module_name.Unique.Set.union set)
        |> Module_name.Unique.Set.to_list_map ~f:Module_name.Unique.to_string
        |> Io.write_lines (Path.build target))
    ;;
  end

  module Action = Action_ext.Make (Spec)

  let action ~transitive ~immediate ~target =
    Action.action { transitive; immediate; target }
  ;;
end

let parse_module_names ~dir ~(unit : Module.t) ~modules words =
  List.concat_map words ~f:(fun m ->
    let m = Module_name.of_checked_string m in
    match Modules.With_vlib.find_dep modules ~of_:unit m with
    | Ok s -> s
    | Error `Parent_cycle ->
      User_error.raise
        [ Pp.textf
            "Module %s in directory %s depends on %s."
            (Module_name.to_string (Module.name unit))
            (Path.to_string_maybe_quoted (Path.build dir))
            (Module_name.to_string m)
        ; Pp.textf "This doesn't make sense to me."
        ; Pp.nop
        ; Pp.textf
            "%s is the main module of the library and is the only module exposed outside \
             of the library. Consequently, it should be the one depending on all the \
             other modules in the library."
            (Module_name.to_string m)
        ])
;;

let parse_compilation_units ~modules =
  let obj_map = Modules.With_vlib.obj_map modules in
  List.filter_map ~f:(fun m ->
    let obj_name = Module_name.Unique.of_string m in
    Module_name.Unique.Map.find obj_map obj_name
    |> Option.map ~f:Modules.Sourced_module.to_module)
;;

let parse_deps_exn =
  let invalid file lines =
    User_error.raise
      [ Pp.textf
          "ocamldep returned unexpected output for %s:"
          (Path.to_string_maybe_quoted file)
      ; Pp.vbox
          (Pp.concat_map lines ~sep:Pp.cut ~f:(fun line ->
             Pp.seq (Pp.verbatim "> ") (Pp.verbatim line)))
      ]
  in
  fun ~file lines ->
    match lines with
    | [] | _ :: _ :: _ -> invalid file lines
    | [ line ] ->
      (match String.lsplit2 line ~on:':' with
       | None -> invalid file lines
       | Some (basename, deps) ->
         let basename = Filename.basename basename in
         if basename <> Path.basename file then invalid file lines;
         String.extract_blank_separated_words deps)
;;

let transitive_deps =
  let transive_dep obj_dir m ~for_ =
    (match Module.kind m with
     | Root | Alias _ -> None
     | _ -> if Module.has m ~ml_kind:Intf then Some Ml_kind.Intf else Some Impl)
    |> Option.map ~f:(fun ml_kind ->
      Obj_dir.Module.dep obj_dir ~for_ (Transitive (m, ml_kind))
      |> Option.value_exn (* we already checked if it's an alias module *)
      |> Path.build)
  in
  fun obj_dir modules ~for_ -> List.filter_map modules ~f:(transive_dep obj_dir ~for_)
;;

let deps_of ~sandbox ~modules ~sctx ~dir ~obj_dir ~ml_kind ~for_ unit =
  let source = Option.value_exn (Module.source unit ~ml_kind) in
  let dep = Obj_dir.Module.dep obj_dir ~for_ in
  let ocamldep_output = dep (Immediate (unit, ml_kind)) |> Option.value_exn in
  let* () =
    let context = Super_context.context sctx in
    let ocamldep =
      (let+ ocaml = Context.ocaml context in
       ocaml.ocamldep)
      |> Action_builder.of_memo
    in
    Super_context.add_rule
      sctx
      ~dir
      (let open Action_builder.With_targets.O in
       let flags, sandbox =
         Module.pp_flags unit |> Option.value ~default:(Action_builder.return [], sandbox)
       in
       Command.run_dyn_prog
         ocamldep
         ~dir:(Path.build (Context.build_dir context))
         ~stdout_to:ocamldep_output
         [ A "-modules"
         ; Command.Args.dyn flags
         ; Command.Ml_kind.flag ml_kind
         ; Dep (Module.File.path source)
         ]
       >>| Action.Full.add_sandbox sandbox)
  in
  let all_deps_file = dep (Transitive (unit, ml_kind)) |> Option.value_exn in
  let+ () =
    let produce_all_deps =
      let open Action_builder.O in
      (let+ transitive, immediate =
         (let+ immediate_deps =
            Path.build ocamldep_output
            |> Action_builder.lines_of
            >>| parse_deps_exn ~file:(Module.File.path source)
            >>| parse_module_names ~dir ~unit ~modules
            >>| Stdlib.( @ ) (Modules.With_vlib.implicit_deps modules ~of_:unit)
          in
          let transitive_deps = transitive_deps obj_dir immediate_deps ~for_ in
          let immediate_deps = List.map immediate_deps ~f:Module.obj_name in
          (transitive_deps, immediate_deps), transitive_deps)
         |> Action_builder.dyn_paths
       in
       Merge_files_into.action ~transitive ~immediate ~target:all_deps_file)
      |> Action_builder.with_file_targets ~file_targets:[ all_deps_file ]
    in
    Action_builder.With_targets.map ~f:Action.Full.make produce_all_deps
    |> Super_context.add_rule sctx ~dir
  in
  let all_deps_file = Path.build all_deps_file in
  Action_builder.lines_of all_deps_file
  |> Action_builder.map ~f:(parse_compilation_units ~modules)
  |> Action_builder.memoize (Path.to_string all_deps_file)
;;

let read_deps_of ~obj_dir ~modules ~ml_kind ~for_ unit =
  let all_deps_file =
    Obj_dir.Module.dep obj_dir ~for_ (Transitive (unit, ml_kind)) |> Option.value_exn
  in
  Action_builder.lines_of (Path.build all_deps_file)
  |> Action_builder.map ~f:(parse_compilation_units ~modules)
  |> Action_builder.memoize (Path.Build.to_string all_deps_file)
;;

(* Parse the raw dependency names from an ocamldep output file. The
   builder for each .d file is cached by path so that
   [read_immediate_deps_of] and [read_immediate_deps_raw_of] (which
   may be called many times for the same module) share one memoized
   [Action_builder.t] instance per file. *)
let read_immediate_deps_parsed =
  let cache = Table.create (module Path.Build) 64 in
  fun ~obj_dir ~ml_kind ~for_ unit ->
    match Module.source ~ml_kind unit with
    | None -> Action_builder.return None
    | Some source ->
      (match Obj_dir.Module.dep obj_dir ~for_ (Immediate (unit, ml_kind)) with
       | None -> Action_builder.return None
       | Some ocamldep_output ->
         (match Table.find cache ocamldep_output with
          | Some builder -> builder
          | None ->
            let builder =
              Action_builder.lines_of (Path.build ocamldep_output)
              |> Action_builder.map ~f:(fun lines ->
                Some (parse_deps_exn ~file:(Module.File.path source) lines))
              |> Action_builder.memoize (Path.Build.to_string ocamldep_output)
            in
            Table.set cache ocamldep_output builder;
            builder))
;;

let read_immediate_deps_of ~obj_dir ~modules ~ml_kind ~for_ unit =
  let open Action_builder.O in
  let+ parsed = read_immediate_deps_parsed ~obj_dir ~ml_kind ~for_ unit in
  match parsed with
  | None -> []
  | Some names -> parse_module_names ~dir:(Obj_dir.dir obj_dir) ~unit ~modules names
;;

let read_immediate_deps_raw_of ~obj_dir ~ml_kind ~for_ unit =
  let open Action_builder.O in
  let+ parsed = read_immediate_deps_parsed ~obj_dir ~ml_kind ~for_ unit in
  match parsed with
  | None -> Module_name.Set.empty
  | Some names -> Module_name.Set.of_list_map names ~f:Module_name.of_checked_string
;;

(* Run ocamldep on a single source file as a memoised computation rather
   than as an [Action_builder] build rule. The computation depends on the
   source file's content digest via [Fs_memo.file_digest]; when the
   source is unchanged across builds, dune's memo system serves the
   cached result without re-reading the file or re-invoking ocamldep.
   Produces no build artefact (no [.d]/[.all-deps] in [_build/]).

   Caching is keyed on [(source, ml_kind)] via [Memo.create] so that
   repeat calls with the same arguments share one memo cell and spawn
   ocamldep at most once per (source, ml_kind) per build. Without this
   explicit cell every caller would construct a fresh [Memo.t] and the
   same ocamldep invocation would fire on every evaluation. [env] and
   [ocamldep] are stable within a build context, so keying on them is
   unnecessary; they're captured implicitly per memo cell via [Memo.cell]
   closure. *)
module Raw_deps_key = struct
  type t = Path.Outside_build_dir.t * Ml_kind.t

  let ml_kind_tag : Ml_kind.t -> int = function
    | Impl -> 0
    | Intf -> 1
  ;;

  let equal (s1, k1) (s2, k2) =
    Path.Outside_build_dir.equal s1 s2 && ml_kind_tag k1 = ml_kind_tag k2
  ;;

  let hash (s, k) =
    Tuple.T2.hash Path.Outside_build_dir.hash Int.hash (s, ml_kind_tag k)
  ;;

  let to_dyn (s, k) =
    let open Dyn in
    Tuple [ Path.Outside_build_dir.to_dyn s; Ml_kind.to_dyn k ]
  ;;
end

let raw_deps_memo =
  let impl ~env ~ocamldep (source, ml_kind) =
    let open Memo.O in
    let source_path = Path.outside_build_dir source in
    let* (_ : Dune_digest.Digest_result.t) = Fs_memo.file_digest source in
    let+ lines =
      Process.run_capture_lines
        ~display:Quiet
        ~env
        Strict
        ocamldep
        [ "-modules"
        ; Ml_kind.choose ml_kind ~impl:"-impl" ~intf:"-intf"
        ; Path.to_string source_path
        ]
      |> Memo.of_reproducible_fiber
    in
    parse_deps_exn ~file:source_path lines
    |> Module_name.Set.of_list_map ~f:Module_name.of_checked_string
  in
  (* One memo cell per unique [(env, ocamldep)] pair. In practice there
     is a single pair per build context, so the outer [Table] is usually
     size 1-2; what matters is that each (source, ml_kind) reuses the
     inner memo's cache instead of reconstructing it on every call. *)
  let table = Table.create (module Path) 4 in
  fun ~env ~ocamldep ~source ~ml_kind ->
    let memo =
      match Table.find table ocamldep with
      | Some m -> m
      | None ->
        let m =
          Memo.create
            "raw_deps_memo"
            ~input:(module Raw_deps_key)
            (impl ~env ~ocamldep)
        in
        Table.set table ocamldep m;
        m
    in
    Memo.exec memo (source, ml_kind)
;;

(* [Module.File.path] holds a staged [_build/<context>/…] path even for
   files the user authored. Recover the source-tree path that
   [Fs_memo.file_digest] can consume by stripping the context prefix via
   [Path.Build.drop_build_context]. Paths already outside [_build/]
   (e.g. external sources) pass through. Returns [None] for files whose
   path has no source-tree counterpart — rule-generated sources whose
   content comes from an upstream build rule rather than the source
   tree. Callers that encounter [None] must fall back to a path that
   can read the build-time file. *)
let source_of_file file : Path.Outside_build_dir.t option =
  let p = Module.File.path file in
  match Path.as_outside_build_dir p with
  | Some outside -> Some outside
  | None ->
    (match Path.as_in_build_dir p with
     | None -> None
     | Some bp ->
       Path.Build.drop_build_context bp
       |> Option.map ~f:(fun src -> Path.Outside_build_dir.In_source_dir src))
;;

(* Resolve the raw module names from [raw_deps_memo] into the subset of
   [modules] that [unit]'s [ml_kind] source immediately depends on, using
   the same name-resolution rules as [parse_module_names] (cross-library
   references are dropped). Augments with [implicit_deps] to match the
   shape produced by [deps_of]'s subprocess path.

   Returns [Memo.return []] in three cases that all semantically denote
   "no intra-stanza dependencies":
   - [unit] has no source for [ml_kind] at all;
   - the source is flagged [implicit] — synthesised by dune itself (the
     empty interface stub from [with_empty_intf], alias/root [ml-gen]
     bodies, wrapped-compat shims) — and so has statically-empty deps;
   - [Module.File.path]'s build path has no source-tree counterpart and
     the caller is expected to fall back to the build-rule path. *)
let immediate_deps_memo ~modules ~dir ~env ~ocamldep ~unit ~ml_kind =
  let open Memo.O in
  match Module.source unit ~ml_kind with
  | None ->
    (* No source for this [ml_kind]: the build-rule path short-circuits
       via [skip_if_source_absent] to the empty list; match that here
       instead of returning [implicit_deps]. *)
    Memo.return []
  | Some file ->
    let implicit = Modules.With_vlib.implicit_deps modules ~of_:unit in
    if Module.File.implicit file
    then
      (* [Module.File.implicit]: file synthesised by dune (empty [.mli]
         stub, [.ml-gen] body). ocamldep on it would return the empty
         set; match that plus [implicit_deps]. *)
      Memo.return implicit
    else (
      match source_of_file file with
      | None ->
        (* Source path has no source-tree counterpart. The caller that
           gated on [stanza_can_use_memo] ensures we never reach here
           for memoisable stanzas, but be defensive: yield the same
           shape the source-absent case does. *)
        Memo.return []
      | Some source ->
        let+ names = raw_deps_memo ~env ~ocamldep ~source ~ml_kind in
        let parsed =
          Module_name.Set.to_list_map names ~f:Module_name.to_string
          |> parse_module_names ~dir ~unit ~modules
        in
        implicit @ parsed)
;;

module Parallel_map = Memo.Make_parallel_map (Module_name.Unique.Map)

(* Build an intra-stanza map from [obj_name] to the immediate dependency
   list discovered by [immediate_deps_memo] for every module in
   [modules], concurrently. Each per-module [raw_deps_memo] cell is
   cached on its source-file digest, so repeat calls within a build are
   free after the first. *)
let immediate_deps_map_memo ~modules ~dir ~env ~ocamldep ~ml_kind =
  Modules.With_vlib.obj_map modules
  |> Parallel_map.parallel_map ~f:(fun _obj_name sm ->
    let unit = Modules.Sourced_module.to_module sm in
    immediate_deps_memo ~modules ~dir ~env ~ocamldep ~unit ~ml_kind)
;;

module Top_closure_id =
  Top_closure.Make (Module_name.Unique.Set) (Monad.Id)

(* Pure transitive closure of a module's intra-stanza dependencies,
   computed from a pre-built immediate-deps map. Matches the shape of
   what the [.all-deps] file would contain: the module's transitive
   closure, minus the module itself. Dependency cycles surface as a
   [User_error] with the same wording [Dep_graph.top_closed] uses for
   the build-rule path, so test expectations remain invariant across
   the memo migration. *)
let transitive_closure_from_map ~immediate ~dir (unit : Module.t) =
  let result =
    Top_closure_id.top_closure
      [ unit ]
      ~key:Module.obj_name
      ~deps:(fun m ->
        Module_name.Unique.Map.find immediate (Module.obj_name m)
        |> Option.value ~default:[])
  in
  match result with
  | Ok modules ->
    List.filter modules ~f:(fun m ->
      not (Module_name.Unique.equal (Module.obj_name m) (Module.obj_name unit)))
  | Error cycle ->
    User_error.raise
      [ Pp.textf "dependency cycle between modules in %s:" (Path.Build.to_string dir)
      ; Pp.chain cycle ~f:(fun m -> Pp.verbatim (Module_name.to_string (Module.name m)))
      ]
;;

(* Same shape as [read_deps_of] / [deps_of], but computed entirely in
   memory from [raw_deps_memo] results. No build rules, no [.d] or
   [.all-deps] files. The returned list is the transitive closure of
   [unit]'s intra-stanza dependencies, excluding [unit] itself. *)
let deps_of_memo ~modules ~dir ~env ~ocamldep ~ml_kind unit =
  let open Memo.O in
  let+ immediate = immediate_deps_map_memo ~modules ~dir ~env ~ocamldep ~ml_kind in
  transitive_closure_from_map ~immediate ~dir unit
;;

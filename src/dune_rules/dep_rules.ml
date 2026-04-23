open Import
open Memo.O
module Parallel_map = Memo.Make_parallel_map (Module_name.Unique.Map)

let transitive_deps_contents modules =
  List.map modules ~f:(fun m ->
    (* TODO use object names *)
    Modules.Sourced_module.to_module m |> Module.name |> Module_name.to_string)
  |> String.concat ~sep:"\n"
;;

let ooi_deps
      ~vimpl
      ~sctx
      ~dir
      ~obj_dir
      ~dune_version
      ~vlib_obj_map
      ~(ml_kind : Ml_kind.t)
      ~for_
      (sourced_module : Modules.Sourced_module.t)
  =
  let m = Modules.Sourced_module.to_module sourced_module in
  let* read =
    let unit =
      let cm_kind =
        match ml_kind with
        | Intf -> Cm_kind.Cmi
        | Impl -> vimpl |> Vimpl.impl_cm_kind
      in
      Obj_dir.Module.cm_file_exn obj_dir m ~kind:(Ocaml cm_kind) |> Path.build
    in
    let sandbox =
      if dune_version >= (3, 3) then Some Sandbox_config.needs_sandboxing else None
    in
    let+ ocaml =
      let ctx = Super_context.context sctx in
      Context.ocaml ctx
    in
    Ocamlobjinfo.rules ocaml ~sandbox ~dir ~units:[ unit ]
    |> Action_builder.map ~f:(function
      | [ x ] -> x
      | [] | _ :: _ -> assert false)
  in
  let add_rule = Super_context.add_rule sctx ~dir in
  let read =
    Action_builder.memoize
      "ocamlobjinfo"
      (let open Action_builder.O in
       let+ (ooi : Ocamlobjinfo.t) = read in
       Module_name.Unique.Set.to_list ooi.intf
       |> List.filter_map ~f:(fun dep ->
         if Module.obj_name m = dep
         then None
         else Module_name.Unique.Map.find vlib_obj_map dep))
  in
  let+ () =
    add_rule
      (let target =
         Obj_dir.Module.dep obj_dir ~for_ (Transitive (m, ml_kind)) |> Option.value_exn
       in
       Action_builder.map read ~f:transitive_deps_contents
       |> Action_builder.write_file_dyn target)
  in
  read
;;

let wrapped_compat_deps modules m =
  let inner = Modules.compat_for_exn (Modules.With_vlib.drop_vlib modules) m in
  match Modules.With_vlib.lib_interface modules with
  | Some li -> [ li; inner ]
  | None -> [ inner ]
;;

let deps_of_module ~modules ~sandbox ~sctx ~dir ~obj_dir ~ml_kind ~for_ m =
  match Module.kind m with
  | Wrapped_compat ->
    wrapped_compat_deps modules m |> Action_builder.return |> Memo.return
  | _ ->
    let+ deps = Ocamldep.deps_of ~sandbox ~modules ~sctx ~dir ~obj_dir ~ml_kind ~for_ m in
    (match Modules.With_vlib.alias_for modules m with
     | [] -> deps
     | aliases ->
       let open Action_builder.O in
       let+ deps = deps in
       aliases @ deps)
;;

let deps_of_vlib_module ~obj_dir ~vimpl ~dir ~sctx ~ml_kind ~for_ sourced_module =
  match
    let vlib = Vimpl.vlib vimpl in
    Lib.Local.of_lib vlib
  with
  | None ->
    let+ deps =
      let vlib_obj_map = Vimpl.vlib_obj_map vimpl in
      let dune_version =
        let impl = Vimpl.impl vimpl in
        Dune_project.dune_version impl.project
      in
      ooi_deps
        ~vimpl
        ~sctx
        ~dir
        ~obj_dir
        ~dune_version
        ~vlib_obj_map
        ~ml_kind
        ~for_
        sourced_module
    in
    Action_builder.map deps ~f:(List.map ~f:Modules.Sourced_module.to_module)
  | Some lib ->
    let vlib_obj_dir =
      let info = Lib.Local.info lib in
      Lib_info.obj_dir info
    in
    let m = Modules.Sourced_module.to_module sourced_module in
    let+ () =
      let src =
        Obj_dir.Module.dep vlib_obj_dir ~for_ (Transitive (m, ml_kind))
        |> Option.value_exn
        |> Path.build
      in
      let dst =
        Obj_dir.Module.dep obj_dir ~for_ (Transitive (m, ml_kind)) |> Option.value_exn
      in
      Super_context.add_rule sctx ~dir (Action_builder.symlink ~src ~dst)
    in
    let modules = Vimpl.vlib_modules vimpl |> Modules.With_vlib.modules in
    Ocamldep.read_deps_of ~obj_dir:vlib_obj_dir ~modules ~ml_kind ~for_ m
;;

(** Tests whether a set of modules is a singleton. *)
let has_single_file modules = Option.is_some @@ Modules.With_vlib.as_singleton modules

(** Tests whether ocamldep can be short-circuited for [modules]: true for
    single-module stanzas that have no library dependencies, since no
    consumer of ocamldep output can benefit in that case. *)
let skip_ocamldep ~has_library_deps modules =
  has_single_file modules && not has_library_deps
;;

let rec deps_of
          ~obj_dir
          ~modules
          ~sandbox
          ~impl
          ~dir
          ~sctx
          ~ml_kind
          ~for_
          ~has_library_deps
          (m : Modules.Sourced_module.t)
  =
  let is_alias_or_root =
    match m with
    | Impl_of_virtual_module _ -> false
    | Imported_from_vlib m | Normal m ->
      (match Module.kind m with
       | Root | Alias _ -> true
       | _ -> false)
  in
  if is_alias_or_root || skip_ocamldep ~has_library_deps modules
  then Memo.return (Action_builder.return [])
  else (
    let skip_if_source_absent f sourced_module =
      let m = Modules.Sourced_module.to_module m in
      if Module.has m ~ml_kind
      then f sourced_module
      else Memo.return (Action_builder.return [])
    in
    match m with
    | Imported_from_vlib _ ->
      let vimpl = Virtual_rules.vimpl_exn impl in
      skip_if_source_absent
        (deps_of_vlib_module ~obj_dir ~vimpl ~dir ~sctx ~ml_kind ~for_)
        m
    | Normal m ->
      skip_if_source_absent
        (deps_of_module ~modules ~sandbox ~sctx ~dir ~obj_dir ~ml_kind ~for_)
        m
    | Impl_of_virtual_module impl_or_vlib ->
      deps_of ~obj_dir ~modules ~sandbox ~impl ~dir ~sctx ~ml_kind ~for_ ~has_library_deps
      @@
      let m = Ml_kind.Dict.get impl_or_vlib ml_kind in
      (match ml_kind with
       | Intf -> Imported_from_vlib m
       | Impl -> Normal m))
;;

(* A stanza qualifies for the in-memory memo path when every module:
   - is [Normal] (no virtual-library machinery, no [Virtual] kind), and
   - has no preprocessing, and
   - either has an [implicit] source (dune-synthesised; known-empty
     deps), or has every present source's [source_of_file] path
     existing on disk (rule-generated sources like menhir output have
     a [_build/]-only source and fail this check).

   [Virtual] modules mark the stanza as a virtual library — other
   stanzas implementing it consume this stanza's [.all-deps] files via
   [deps_of_vlib_module]'s symlink rule, so a vlib stanza must keep
   emitting those files regardless of whether its own modules' deps
   could be computed in memory. Rejecting [Virtual] forces the whole
   vlib stanza onto the build-rule pipeline, preserving the symlinks
   that cross-stanza implementations rely on.

   Violating any condition forces the stanza onto the build-rule
   pipeline, because the transitive closure reads each reachable
   module's immediate-dep set and a single wrong entry poisons the
   closure. The source-existence probe is async (uses
   [Fs_memo.file_exists]), so the whole gate is a [bool Memo.t]. *)
let stanza_can_use_memo modules : bool Memo.t =
  Modules.With_vlib.obj_map modules
  |> Module_name.Unique.Map.to_list
  |> Memo.List.for_all ~f:(fun (_, (sm : Modules.Sourced_module.t)) ->
    match sm with
    | Imported_from_vlib _ | Impl_of_virtual_module _ -> Memo.return false
    | Normal m ->
      (match Module.kind m with
       | Root | Alias _ | Wrapped_compat -> Memo.return true
       | Virtual -> Memo.return false
       | Intf_only | Impl | Impl_vmodule | Parameter ->
         if Option.is_some (Module.pp_flags m)
         then Memo.return false
         else
           Memo.List.for_all [ Ml_kind.Impl; Ml_kind.Intf ] ~f:(fun ml_kind ->
             match Module.source m ~ml_kind with
             | None -> Memo.return true
             | Some file ->
               if Module.File.implicit file
               then Memo.return true
               else (
                 match Ocamldep.source_of_file file with
                 | None -> Memo.return false
                 | Some src -> Fs_memo.file_exists src))))
;;

(* Per-stanza immediate-deps map computed via memo, when the stanza
   qualifies. Returned as an [option] so callers can fall back to the
   file-based readers for stanzas the memo path can't handle. *)
let immediate_map_memo_opt ~sctx ~modules ~dir ~ml_kind
  : Module.t list Module_name.Unique.Map.t option Memo.t
  =
  let* gate = stanza_can_use_memo modules in
  if not gate
  then Memo.return None
  else (
    let context = Super_context.context sctx in
    let* ocamldep_prog =
      let+ ocaml = Context.ocaml context in
      ocaml.ocamldep
    in
    match ocamldep_prog with
    | Error _ -> Memo.return None
    | Ok ocamldep ->
      let* env = Context.installed_env context in
      let+ map =
        Ocamldep.immediate_deps_map_memo ~modules ~dir ~env ~ocamldep ~ml_kind
      in
      Some map)
;;

(* [read_deps_of_module] reports intra-stanza module dependencies. For
   single-module stanzas that dependency graph is trivially empty
   regardless of whether the stanza declares library dependencies, so
   we keep the unconditional short-circuit here. When the stanza
   qualifies for the memo path, deps are computed in-memory from the
   memoised ocamldep invocations; otherwise they're read from the
   [.d]/[.all-deps] files the build-rule pipeline emits. *)
let read_deps_of_module ~sctx ~modules ~obj_dir dep ~for_ =
  let (Obj_dir.Module.Dep.Immediate (unit, _) | Transitive (unit, _)) = dep in
  match Module.kind unit with
  | Root | Alias _ -> Action_builder.return []
  | Wrapped_compat -> wrapped_compat_deps modules unit |> Action_builder.return
  | _ ->
    if has_single_file modules
    then Action_builder.return []
    else (
      let via_files ~dep =
        match dep with
        | Obj_dir.Module.Dep.Immediate (unit, ml_kind) ->
          Ocamldep.read_immediate_deps_of ~obj_dir ~modules ~ml_kind ~for_ unit
        | Transitive (unit, ml_kind) ->
          let open Action_builder.O in
          let+ deps = Ocamldep.read_deps_of ~obj_dir ~modules ~ml_kind ~for_ unit in
          (match Modules.With_vlib.alias_for modules unit with
           | [] -> deps
           | aliases -> aliases @ deps)
      in
      let via_memo ~dep ~map =
        match dep with
        | Obj_dir.Module.Dep.Immediate (unit, _ml_kind) ->
          Module_name.Unique.Map.find map (Module.obj_name unit)
          |> Option.value ~default:[]
          |> Action_builder.return
        | Transitive (unit, _ml_kind) ->
          let dir = Obj_dir.dir obj_dir in
          let transitive =
            Ocamldep.transitive_closure_from_map ~immediate:map ~dir unit
          in
          let with_aliases =
            match Modules.With_vlib.alias_for modules unit with
            | [] -> transitive
            | aliases -> aliases @ transitive
          in
          Action_builder.return with_aliases
      in
      let dir = Obj_dir.dir obj_dir in
      let ml_kind =
        match dep with
        | Immediate (_, k) | Transitive (_, k) -> k
      in
      Action_builder.bind
        (Action_builder.of_memo
           (immediate_map_memo_opt ~sctx ~modules ~dir ~ml_kind))
        ~f:(function
          | Some map -> via_memo ~dep ~map
          | None -> via_files ~dep))
;;

let read_immediate_deps_of ~sctx ~obj_dir ~modules ~ml_kind ~for_ m =
  read_deps_of_module ~sctx ~modules ~obj_dir (Immediate (m, ml_kind)) ~for_
;;

let read_deps_of ~sctx ~obj_dir ~modules ~ml_kind ~for_ m =
  if Module.has m ~ml_kind
  then read_deps_of_module ~sctx ~modules ~obj_dir (Transitive (m, ml_kind)) ~for_
  else Action_builder.return []
;;

let dict_of_func_concurrently f =
  let+ impl = f ~ml_kind:Ml_kind.Impl
  and+ intf = f ~ml_kind:Ml_kind.Intf in
  Ml_kind.Dict.make ~impl ~intf
;;

(* Shape the per-module dep list the same way the build-rule path does:
   [Root]/[Alias] have no intra-stanza deps; [Wrapped_compat] has its
   static alias list; everything else gets its transitive closure
   augmented with [alias_for]'s modules prepended. *)
let deps_for_module_from_map ~modules ~immediate ~dir (m : Module.t) =
  match Module.kind m with
  | Root | Alias _ -> []
  | Wrapped_compat -> wrapped_compat_deps modules m
  | _ ->
    let transitive = Ocamldep.transitive_closure_from_map ~immediate ~dir m in
    (match Modules.With_vlib.alias_for modules m with
     | [] -> transitive
     | aliases -> aliases @ transitive)
;;

(* Build a [Dep_graph.t] from a precomputed immediate-deps map. *)
let dep_graph_from_map ~modules ~dir ~immediate =
  let per_module =
    Modules.With_vlib.obj_map modules
    |> Module_name.Unique.Map.map ~f:(fun sm ->
      let m = Modules.Sourced_module.to_module sm in
      let deps = deps_for_module_from_map ~modules ~immediate ~dir m in
      Action_builder.return deps)
  in
  Dep_graph.make ~dir ~per_module
;;

let for_module ~obj_dir ~modules ~sandbox ~impl ~dir ~sctx ~for_ module_ =
  dict_of_func_concurrently
    (deps_of
       ~obj_dir
       ~modules
       ~sandbox
       ~impl
       ~dir
       ~sctx
       ~for_
       ~has_library_deps:true
       (Normal module_))
;;

let rules ~obj_dir ~modules ~sandbox ~impl ~sctx ~dir ~for_ ~has_library_deps =
  let rules_via_files () =
    dict_of_func_concurrently (fun ~ml_kind ->
      let+ per_module =
        Modules.With_vlib.obj_map modules
        |> Parallel_map.parallel_map ~f:(fun _obj_name m ->
          deps_of
            ~obj_dir
            ~modules
            ~sandbox
            ~impl
            ~sctx
            ~dir
            ~ml_kind
            ~for_
            ~has_library_deps
            m)
      in
      Dep_graph.make ~dir ~per_module)
    |> Memo.map ~f:(Dep_graph.Ml_kind.for_module_compilation ~modules)
  in
  match Modules.With_vlib.as_singleton modules with
  | Some m when not has_library_deps -> Memo.return (Dep_graph.Ml_kind.dummy m)
  | Some _ | None ->
    let try_memo ~ml_kind =
      immediate_map_memo_opt ~sctx ~modules ~dir ~ml_kind
    in
    let* impl_map = try_memo ~ml_kind:Ml_kind.Impl
    and* intf_map = try_memo ~ml_kind:Ml_kind.Intf in
    (match impl_map, intf_map with
     | Some impl_map, Some intf_map ->
       let impl = dep_graph_from_map ~modules ~dir ~immediate:impl_map in
       let intf = dep_graph_from_map ~modules ~dir ~immediate:intf_map in
       Memo.return
         (Dep_graph.Ml_kind.for_module_compilation ~modules { impl; intf })
     | _ -> rules_via_files ())
;;

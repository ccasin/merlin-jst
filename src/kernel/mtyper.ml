open Std

type typedtree = [
  | `Interface of Typedtree.signature
  | `Implementation of Typedtree.structure
]

type result = {
  id        : int;
  config    : Mconfig.t;
  state     : Mocaml.typer_state;
  errors    : exn list;
  checks    : Typecore.delayed_check list;
  typedtree : typedtree;
}

let id = let k = ref 0 in fun () -> incr k; !k

let print_result () {id; _} =
  sprintf "<Mtyper.result%d>" id

let run tr config source parsetree =
  Trace.enter tr
    "Mtyper.run %a %a %a"
    (Json.print Mconfig.dump) config
    (Json.print Msource.dump) source
    (fun () -> function `Implementation _ -> "Implementation _"
                      | `Interface _ -> "Interface _")
    parsetree
    ~return:print_result
  @@ fun tr ->
  Mocaml.setup_config config;
  let state = Mocaml.new_state ~unit_name:(Msource.unitname source) in
  Mocaml.with_state state @@ fun () ->
  let caught = ref [] in
  Msupport.catch_errors Mconfig.(config.ocaml.warnings) caught @@ fun () ->
  Typecore.reset_delayed_checks ();
  let env0 = Typer_raw.fresh_env () in
  let env0 = Env.open_pers_signature "Pervasives" env0 in
  let env0 = Extension.register Mconfig.(config.merlin.extensions) env0 in
  let location = {
    Location.
    loc_start = Msource.get_lexing_pos tr source `Start;
    loc_end = Msource.get_lexing_pos tr source `End;
    loc_ghost = false;
  } in
  let typedtree = match parsetree with
    | `Implementation impl ->
      let tree, sg, env = Typemod.type_structure env0 impl location in
      `Implementation tree
    | `Interface intf ->
      let sg = Typemod.transl_signature env0 intf in
      `Interface sg
  in
  let checks = !Typecore.delayed_checks in
  let errors = !caught in
  Typecore.reset_delayed_checks ();
  { id = id (); config; state; typedtree; checks; errors }

let with_typer t f =
  Mocaml.with_state t.state f

let get_typedtree t =
  assert (Mocaml.is_state t.state);
  t.typedtree

let get_env ?pos t =
  assert (Mocaml.is_state t.state);
  match t.typedtree with
  | `Implementation str -> str.Typedtree.str_final_env
  | `Interface sg -> sg.Typedtree.sig_final_env

let get_errors t =
  assert (Mocaml.is_state t.state);
  let caught = ref t.errors in
  Typecore.delayed_checks := t.checks;
  Msupport.catch_errors Mconfig.(t.config.ocaml.warnings) caught
    Typecore.force_delayed_checks;
  Typecore.reset_delayed_checks ();
  (!caught)

let node_at tr ?(skip_recovered=false) t pos_cursor =
  Trace.enter tr "Mtyper.node_at %a %a"
    print_result t Lexing.print_position pos_cursor
    ~return:Mbrowse.print
  @@ fun tr ->
  assert (Mocaml.is_state t.state);
  let node = Mbrowse.of_typedtree (get_typedtree t) in
  let rec select = function
    (* If recovery happens, the incorrect node is kept and a recovery node
       is introduced, so the node to check for recovery is the second one. *)
    | (_,node) :: ((_,node') :: _ as ancestors)
      when Mbrowse.is_recovered node' -> select ancestors
    | l -> l
  in
  match Mbrowse.deepest_before tr pos_cursor [node] with
  | [] -> [get_env t, Browse_raw.Dummy]
  | path when skip_recovered -> select path
  | path -> path
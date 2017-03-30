(** This module implements a compiler from Fopix to Retrolix. *)

let error pos msg =
  Error.error "compilation" pos msg

(** As in any module that implements {!Compilers.Compiler}, the source
    language and the target language must be specified. *)
module Source = Fopix
module Target = Retrolix
module S = Source.AST
module T = Target.AST

(** We will need the following pieces of information to be carrying
    along the translation: *)
module IdCmp = struct
  type t = T.identifier
  let compare = compare
end
module IdSet = Set.Make (IdCmp)

(** The compilation environment stores the list of global
    variables (to compute local variables) and a table
    representing a renaming (for alpha-conversion). *)
type environment = IdSet.t * (S.identifier * S.identifier) list

(** Initially, the environment is empty. *)
let initial_environment () = (IdSet.empty, [])

(** [fresh_label ()] returns a new identifier for a label. *)
let fresh_label =
  let c = ref 0 in
  fun () -> incr c; T.Label ("l" ^ string_of_int !c)

(** [fresh_label ()] returns a new identifier for a variable. *)
let fresh_variable =
  let c = ref 0 in
  fun () -> incr c; T.(Id ("X" ^ string_of_int !c))

let fresh_id =
  let c = ref 0 in
  fun () -> incr c; string_of_int !c

let identifier (S.Id x) = T.Id x

let idset_of_idlist ids =
  List.fold_left (fun acc id -> IdSet.add id acc) IdSet.empty ids

(**
   Every function in Retrolix starts with a declaration
   of local variables. So we need a way to compute the
   local variables of some generated code. This is the
   purpose of the next functions:
*)

let local globals instr = T.(
    let local = function
      | `Variable id ->
        if IdSet.mem id globals then IdSet.empty else IdSet.singleton id
      | `Register _ | `Immediate _ -> IdSet.empty
    in
    let ( ++ ) = IdSet.union in
    let locals xs = List.fold_left ( ++ ) IdSet.empty (List.map local xs) in
    match instr with
    | Call (l, r, rs) -> local l ++ local r ++ locals rs
    | TailCall (r, rs) -> local r ++ locals rs
    | Ret r -> local r
    | Assign (l, _, rs) -> local l ++ locals rs
    | Jump _ | Comment _ | Exit -> IdSet.empty
    | ConditionalJump (_, rs, _, _) -> locals rs
    | Switch (r, _, _) -> local r
  )

(** [locals globals formals b] takes a set of variables [globals] and
    a set of variables [formals] and returns the variables use in the
    list of instructions [b] which are not in [globals] or [formals]. *)
let locals globals formals b =
  IdSet.elements (
    IdSet.diff
      (List.fold_left
         IdSet.union
         IdSet.empty
         (List.map (fun (_, instr) -> local globals instr) b))
      formals
  )

let register r = T.(`Register (RId (MipsArch.string_of_register r)))

let rec get_globals set = function
  | S.DefineValue (x, _) -> push set x
  | _ -> set 

and push set x = 
  IdSet.add (identifier x) set

let rec preprocess defList env =
  let (globals, renaming) = env in
  let globals = List.fold_left get_globals globals defList in
  let env = (globals, renaming) in
  let defs = List.map (declaration env) defList in
  (defs, env)

and check_and_generate_new_id env x = 
  let (globals, renaming) = env in
  try 
    let _ = IdSet.find (identifier x) globals in
    let newX, newRenaming = generate_new_id renaming x in
    let newEnv = (globals, newRenaming) in
    newEnv, newX
  with
  | Not_found -> env, x 

and generate_new_id renaming x =
  try 
    let existId = List.assoc x renaming in
    generate_new_id renaming existId
  with
    | Not_found ->
      let S.Id s = x in
      let newId = S.Id(s ^ fresh_id ()) in
      newId, (x, newId)::renaming

and declaration env p = match p with
    | S.DefineValue (x, e) ->
      let env, newE = expression env e in
      let env, newX = check_and_generate_new_id env x in
      S.DefineValue (newX, newE)

    | S.DefineFunction (f, xs, e) ->
      let (g, r) = initial_environment () in
      let globals = List.fold_left (fun acc s -> (IdSet.add (identifier s) acc)) g xs in
      let envForFun = (globals, r) in
      let _, newE = expression envForFun e in
      S.DefineFunction (f, xs, newE)

    | _ -> p

and expression env e = match e with
    | _ -> env, e (* TODO *)

(** [translate' p env] turns a Fopix program [p] into a Retrolix
    program using [env] to retrieve contextual information. *)
let rec translate' p env =
  (** The global variables are extracted in a first pass. *)
  let (globals, renaming) = env in
  let globals = List.fold_left get_globals globals p in
  let env = (globals, renaming) in
  let p, env = preprocess p env in
  (** Then, we translate Fopix declarations into Retrolix declarations. *)
  let defs = List.map (declaration globals) p in
  (defs, env)

(* and register r = *)
(*   T.((`Register (RId (MipsArch.string_of_register r)) : lvalue)) *)
(*
and get_globals env = function
  | S.DefineValue (x, _) ->
    push env x
  | _ ->
    env

and push env x =
  IdSet.add (identifier x) env
*)
and declaration env = T.(function
    | S.DefineValue (S.Id x, e) ->
      let x = Id x in
      let ec = expression (`Variable x) e in
      let locals = locals env IdSet.empty ec in
      DValue (x, (locals, ec))

    | S.DefineFunction (S.FunId f, xs, e) ->
      let return_register = register MipsArch.return_register in
      let ec = expression return_register e in
      let formals = List.map identifier xs in
      let ls, save_callee_saved =
        save_registers MipsArch.callee_saved_registers
      in
      DFunction (FId f,
                 formals,
                 (locals env (idset_of_idlist formals) ec,
                  save_callee_saved @ ec @
                  restore_registers MipsArch.callee_saved_registers ls @
                  [labelled (Ret return_register)]))

    | S.ExternalFunction (S.FunId f) ->
      DExternalFunction (FId f)
  )
(** [expression out e] compiles [e] into a block of Retrolix
    instructions that stores the evaluation of [e] into [out]. *)
and expression out = T.(function
    | S.Literal l ->
      [labelled (Assign (out, Load, [ `Immediate (literal l) ]))]

    | S.Variable (S.Id x) ->
      [labelled (Assign (out, Load, [ `Variable (Id x) ]))]

    | S.Define (S.Id x, e1, e2) ->
      (** Hey student! The following code is wrong in general,
          hopefully, you will implement [preprocess] in such a way that
          it will work, right? *)
      expression (`Variable (Id x)) e1 @ expression out e2

    | S.While (c, e) ->
      let closeLabel = [labelled (Comment "Exit While")] in
      let condReg = `Variable (fresh_variable ()) in
      let condIns = expression condReg c in
      let eIns = ( expression out e ) in
      let condJump =
        [ labelled (
              ConditionalJump (
                EQ,
                [ condReg; `Immediate (LInt (Int32.of_int 0)) ],
                first_label closeLabel,
                first_label condIns
              )
            )]
      in
      condIns @ condJump @ eIns @ condJump @ closeLabel

    | S.IfThenElse (c, t, f) ->
      let closeLabel = [labelled (Comment "Exit If")] in
      let jumpToClose = [labelled (Jump (first_label closeLabel))] in
      let insTrue = (expression out t) @ jumpToClose in
      let insFalse = (expression out f) @ jumpToClose in
      (condition (first_label insTrue) (first_label insFalse) c) @
      insTrue @ insFalse @ closeLabel

    | S.FunCall (S.FunId f, es) when is_binop f ->
      assign out (binop f) es

    | S.FunCall (f, actuals) ->
      let fst_four_actuals, extra_actuals = split_actuals actuals in
      let ais, pass_fst_four_actuals = pass_fst_four_actuals fst_four_actuals in
      let ls, save_caller_saved =
        save_registers MipsArch.caller_saved_registers
      in
      pass_fst_four_actuals @
      as_rvalues extra_actuals
        (fun rs ->
           save_caller_saved @
           [labelled (T.Call (out, `Immediate (literal (S.LFun f)),
                              ais @ rs))]) @
      restore_registers MipsArch.caller_saved_registers ls

    | S.UnknownFunCall (ef, actuals) ->
      failwith "Students! This is your job!"

    | S.Switch (e, cases, default) ->
      let closeLabel = [labelled (Comment "Exit Switch")] in
      let jumpToClose = [labelled (Jump (first_label closeLabel))] in
      let condVar, condIns = as_rvalue e in
      let lsOfCases =
        Array.map (fun c -> ((expression out c) @ jumpToClose)) cases
      in
      let labelsOfLsOfCases = Array.map (fun l -> first_label l) lsOfCases in
      let casesIns = Array.fold_left (fun acc i -> i @ acc ) [] lsOfCases in
      match default with
      | Some expr -> (
          let defaultIns = (expression out expr) @ jumpToClose in
          condIns @
          [labelled (
              Switch(condVar, labelsOfLsOfCases, Some(first_label defaultIns))
            )] @
          casesIns @ defaultIns @ closeLabel)
      | None ->
        condIns @ [labelled (Switch(condVar, labelsOfLsOfCases, None))] @
        casesIns @ closeLabel
  )

and load l r = T.Assign (l, T.Load, [r])

and save_registers regs =
  let save_register reg l = labelled (load l (register reg)) in
  let ls = List.map (fun _ -> `Variable (fresh_variable ())) regs in
  (ls, List.map2 save_register regs ls)

and restore_registers regs ls =
  let restore_register reg l = labelled (load (register reg) l) in
  List.map2 restore_register regs ls

and split_actuals = function
  | a0 :: a1 :: a2 :: a3 :: extra_actuals -> ([a0; a1; a2; a3], extra_actuals)
  | actuals -> (actuals, [])

and inst_jump_to_label l =
  [labelled (T.Jump (first_label l))]

and pass_fst_four_actuals fst_four_actuals =
  let ais = List.mapi (fun i _ -> register (MipsArch.a i)) fst_four_actuals in
  (ais,
   List.flatten (
     List.map2 (fun ai actual -> expression ai actual) ais fst_four_actuals
   ))

and as_rvalue e =
  let x = `Variable (fresh_variable ()) in
  (x, expression x e)

and as_rvalues rs f =
  let xs, es = List.(split (map as_rvalue rs)) in
  List.flatten es @ f xs

and assign out op rs =
  as_rvalues rs (fun xs ->
      [labelled (T.Assign (out, op, xs))]
    )

and condition lt lf c = T.(
    let x = fresh_variable () in
    expression (`Variable x) c
    @ [ labelled (ConditionalJump (EQ, [ `Variable x;
                                         `Immediate (LInt (Int32.of_int 0)) ],
                                   lf,
                                   lt))]
  )

and first_label = function
  | [] -> assert false
  | (l, _) :: _ -> l

and labelled i =
  (fresh_label (), i)

and literal = T.(function
    | S.LInt x ->
      LInt x
    | S.LFun (S.FunId f) ->
      LFun (FId f)
    | S.LChar c ->
      LChar c
    | S.LString s ->
      LString s
  )

and is_binop = function
  | "`+" | "`-" | "`*" | "`/" -> true
  | c -> is_condition c

and is_condition = function
  | "`<" | "`>" | "`=" | "`<=" | "`>=" -> true
  | _ -> false

and binop = T.(function
    | "`+" -> Add
    | "`-" -> Sub
    | "`*" -> Mul
    | "`/" -> Div
    | c -> Bool (condition_op c)
  )

and condition_op = T.(function
    | "`<" -> LT
    | "`>" -> GT
    | "`<=" -> LTE
    | "`>=" -> GTE
    | "`=" -> EQ
    | _ -> assert false
  )

(*
let preprocess p env =
  (p, env)
*)

(** [translate p env] turns the fopix program [p] into a semantically
    equivalent retrolix program. *)
let translate p env =
  (*let p, env = preprocess p env in *)
  let p, env = translate' p env in
  (p, env)

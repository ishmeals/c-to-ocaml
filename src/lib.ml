open Core
open Clang
open Utils
open Scope

[@@@ocaml.warning "-26"]
[@@@ocaml.warning "-27"]

let rec visit_stmt (ast : Ast.stmt) (func_name : string) (mutated_vars: string list)
    (vars : string VarMap.t) (types : (string * string) list VarMap.t) : Scope.t
    =
  match ast.desc with
  | Compound stmt_list ->
      List.fold ~init:("", vars, types)
        ~f:(fun s stmt ->
          Scope.aggregate s
          @@ visit_stmt stmt func_name mutated_vars (Scope.get_vars s) (Scope.get_types s))
        stmt_list
  | Decl decl_list ->
      List.fold ~init:("", vars, types)
        ~f:(fun s decl ->
          Scope.aggregate s
          @@ visit_decl decl mutated_vars (Scope.get_vars s) (Scope.get_types s))
        decl_list
  | Expr expr -> visit_expr expr mutated_vars vars types
  | If { cond; then_branch; else_branch; _ } ->
      ("", vars, types)
      |> Scope.new_level
           ~f:(visit_if_stmt cond then_branch else_branch func_name mutated_vars)
  | For _ ->
      ("", vars, types)
      |> Scope.new_level ~f:(visit_for_stmt ast ("for_" ^ func_name) mutated_vars)
  | While _ ->
      ("", vars, types)
      |> Scope.new_level ~f:(visit_while_stmt ast ("while_" ^ func_name) mutated_vars)
  | Return (Some ret_expr) -> (
      match func_name with
      | "main" ->
          ("", vars, types) |> Scope.add_string "exit("
          |> Scope.extend ~f:(visit_expr ret_expr mutated_vars)
          |> Scope.add_string ")\n"
      | _ -> ("", vars, types) |> Scope.extend ~f:(visit_expr ret_expr mutated_vars))
  | Break -> ("", vars, types) |> Scope.add_string (List.nth_exn mutated_vars ((List.length mutated_vars) - 1))

  | Return None -> ("", vars, types) |> Scope.add_string "()"
  | _ ->
      Clang.Printer.stmt Format.std_formatter ast;
      ("", vars, types)

and visit_if_stmt (cond : Ast.expr) (then_branch : Ast.stmt)
    (else_branch : Ast.stmt option) (func_name : string) (mutated_vars: string list)
    (vars : string VarMap.t) (types : (string * string) list VarMap.t) : Scope.t
    =
  let mutated =
    Collect_vars.collect_mutated_vars then_branch [] |> fun l ->
    match else_branch with
    | Some e -> Collect_vars.collect_mutated_vars e l
    | None -> l
  and else_str (vars : string VarMap.t)
      (types : (string * string) list VarMap.t) =
    match else_branch with
    | Some e -> visit_stmt e func_name mutated_vars vars types
    | None -> ("", vars, types)
  in
  match List.length mutated with
  | 0 ->
      (* TODO this might not work with some edge cases !!! *)
      ("", vars, types) |> Scope.add_string "if "
      |> Scope.extend ~f:(visit_expr cond mutated_vars)
      |> Scope.add_string " then "
      |> Scope.extend ~f:(visit_stmt then_branch func_name mutated_vars)
      |> Scope.add_string " else " |> Scope.extend ~f:else_str
      |> Scope.add_string "\n"
  | _ ->
      let return_str = " (" ^ String.concat ~sep:"," mutated ^ ") " in
      ("", vars, types)
      |> Scope.add_string @@ "let " ^ return_str ^ " = if "
      |> Scope.extend ~f:(visit_expr cond mutated_vars)
      |> Scope.add_string " then "
      |> Scope.extend ~f:(visit_stmt then_branch func_name mutated_vars)
      |> Scope.add_string @@ return_str ^ " else "
      |> Scope.extend ~f:else_str
      |> Scope.add_string @@ return_str ^ " in\n"

and visit_for_stmt (ast : Ast.stmt) (func_name : string) (mutated_vars: string list)
    (vars : string VarMap.t) (types : (string * string) list VarMap.t) : Scope.t
    =
  match ast.desc with
  | For { cond; init; body; inc; _ } ->
      let mutated = Collect_vars.collect_mutated_vars ast [] in

      let allMutated = String.concat ~sep:"," mutated in
      let pass_on_mutated = " ( " ^ allMutated ^ " ) " in
      let varName =
        match init with
        | Some e -> (
            match e.desc with
            | Decl decl_list ->
                List.fold ~init:[]
                  ~f:(fun sArray s -> Collect_vars.get_decl_names s :: sArray)
                  decl_list
            | _ -> failwith "shouldn't occur")
        | None -> failwith "implement later"
      in
      let allVarNames = String.concat ~sep:"," varName in
      let start = ("", vars, types) in
      let initStart =
        match init with
        | Some e -> Scope.extend start ~f:(visit_stmt e func_name (mutated_vars @ [pass_on_mutated]))
        | None -> start
      in
      Scope.add_string
        ("let rec " ^ func_name ^ " (" ^ allMutated ^ ") (" ^ allVarNames
       ^ ") = if not @@ ")
        initStart
      |> Scope.extend ~f:(visit_expr (Option.value_exn cond) (mutated_vars @ [pass_on_mutated]))
      |> Scope.add_string @@ " then "
      |> Scope.add_string @@ "(" ^ allMutated ^ ") \n"
      |> Scope.add_string @@ " else "
      |> Scope.extend ~f:(visit_stmt body func_name (mutated_vars @ [pass_on_mutated]))
      |> Scope.extend ~f:(visit_stmt (Option.value_exn inc) func_name (mutated_vars @ [pass_on_mutated]))
      |> Scope.add_string @@ func_name ^ " (" ^ allMutated ^ ") (" ^ allVarNames
         ^ ") in \n"
      |> Scope.add_string @@ "let (" ^ allMutated ^ ") = " ^ func_name ^ " ("
         ^ allMutated ^ ") (" ^ allVarNames ^ ") in \n"
  | _ -> failwith "never occurs"

and visit_while_stmt (ast : Ast.stmt) (func_name : string) (mutated_vars: string list)
    (vars : string VarMap.t) (types : (string * string) list VarMap.t) : Scope.t
    =
  match ast.desc with
  | While { cond; body; _ } ->
      let mutated = Collect_vars.collect_mutated_vars ast [] in
      let allMutated = String.concat ~sep:"," mutated in
      let pass_on_mutated = " ( " ^ allMutated ^ " ) " in
      ("", vars, types)
      |> Scope.add_string @@ "let rec " ^ func_name ^ " (" ^ allMutated
         ^ ") = if not @@ "
      |> Scope.extend ~f:(visit_expr cond (mutated_vars @ [pass_on_mutated]))
      |> Scope.add_string @@ " then "
      |> Scope.add_string @@ "(" ^ allMutated ^ ") \n"
      |> Scope.add_string @@ " else "
      |> Scope.extend ~f:(visit_stmt body func_name (mutated_vars @ [pass_on_mutated]))
      |> Scope.add_string @@ func_name ^ " (" ^ allMutated ^ ") in \n"
      |> Scope.add_string @@ "let " ^ allMutated ^ " = " ^ func_name ^ " ("
         ^ allMutated ^ ") in \n"
  | _ -> failwith "never occurs"

and visit_function_decl (ast : Ast.function_decl) (mutated_vars: string list) (vars : string VarMap.t)
    (types : (string * string) list VarMap.t) : Scope.t =
  match ast.name with
  | IdentifierName "main" ->
      ("", vars, types)
      |> Scope.add_string "let () =\n"
      |> Scope.extend ~f:(visit_stmt (Option.value_exn ast.body) "main" mutated_vars)
  | IdentifierName name ->
      let let_str =
        match Find_rec.find_rec_func name (Option.value_exn ast.body) with
        | true -> "let rec "
        | false -> "let "
      and return_str =
        match parse_func_return_type ast with
        | "unit" -> "()"
        | return_type -> " : " ^ return_type
      in
      ("", vars, types)
      |> Scope.add_string (let_str ^ name ^ " ")
      |> Scope.extend ~f:(parse_func_params ast)
      |> Scope.add_string (return_str ^ " = \n")
      |> Scope.extend ~f:(visit_stmt (Option.value_exn ast.body) name mutated_vars)
  | _ -> failwith "failure in visit_function_decl"

and visit_struct_decl (ast : Ast.record_decl) (vars : string VarMap.t)
    (types : (string * string) list VarMap.t) : Scope.t =
  ("", vars, types)
  |> Scope.add_string @@ "type " ^ ast.name ^ " = { "
  |> (fun s ->
       List.fold ~init:s
         ~f:(fun s item ->
           Scope.aggregate s
           @@ parse_struct_field item ast.name (Scope.get_vars s)
                (Scope.get_types s))
         ast.fields)
  |> Scope.add_string " }"

and visit_decl (ast : Ast.decl) (mutated_vars: string list) (vars : string VarMap.t)
    (types : (string * string) list VarMap.t) : Scope.t =
  match ast.desc with
  | Function function_decl -> visit_function_decl function_decl mutated_vars vars types 
  | Var var_decl -> (
      let var_type = parse_qual_type var_decl.var_type in
      match var_decl.var_init with
      | Some var_init ->
          ("", vars, types)
          |> Scope.add_var var_decl.var_name var_type
          |> Scope.add_string @@ "let " ^ var_decl.var_name ^ " : " ^ var_type
             ^ " = "
          |> Scope.extend
               ~f:(visit_var_init var_init var_decl.var_name var_type mutated_vars)
          |> Scope.add_string " in\n"
      | None -> visit_empty_init var_decl vars types
      (* ("", vars, types) |> Scope.add_var var_decl.var_name var_type) *))
  | RecordDecl struct_decl -> visit_struct_decl struct_decl vars types
  | EmptyDecl -> ("", vars, types)
  | _ ->
      Clang.Printer.decl Format.std_formatter ast;
      ("", vars, types)

and visit_var_init (ast : Ast.expr) (var_name : string) (var_type : string) (mutated_vars: string list)
    (vars : string VarMap.t) (types : (string * string) list VarMap.t) : Scope.t
    =
  match ast.desc with
  | InitList expr_list -> (
      match Scope.get_type types var_type with
      | Some struct_types ->
          ("", vars, types) |> Scope.add_string "{ "
          |> (fun s ->
               List.fold ~init:s ~f:(fun s item ->
                   let expr, (item_name, item_type) = item in
                   s
                   |> Scope.add_var (var_name ^ "." ^ item_name) item_type
                   |> Scope.add_string @@ item_name ^ " = "
                   |> Scope.extend ~f:(visit_expr expr mutated_vars)
                   |> Scope.add_string "; ")
               @@ List.zip_exn expr_list (List.rev struct_types))
          |> Scope.add_string " }"
      | None -> (
          match List.length expr_list with
          | 0 -> ("[]", vars, types)
          | _ ->
              ("", vars, types) |> Scope.add_string "["
              |> (fun s ->
                   List.fold ~init:s
                     ~f:(fun s item ->
                       Scope.aggregate s
                       @@ visit_expr item mutated_vars (Scope.get_vars s) (Scope.get_types s)
                       |> Scope.add_string "; ")
                     expr_list)
              |> Scope.add_string "]"))
  | _ -> visit_expr ast mutated_vars vars types 

and visit_empty_init (var_decl : Clang.Ast.var_decl_desc)
    (vars : string VarMap.t) (types : (string * string) list VarMap.t) : Scope.t
    =
  let var_name = var_decl.var_name in
  let var_type_name = parse_qual_type var_decl.var_type in
  if is_array_type var_decl.var_type then
    let n = string_of_int (get_array_size var_decl.var_type) in
    ("", vars, types)
    |> Scope.add_var var_name var_type_name
    |> Scope.add_string @@ "let " ^ var_name ^ " : " ^ var_type_name
       ^ " = List.init " ^ n ^ " ~f:(fun _ -> "
       ^ parse_default_value (get_array_type var_decl.var_type)
       ^ ") in \n"
  else ("", vars, types) |> Scope.add_var var_name var_type_name

and visit_expr (ast : Ast.expr) (mutated_vars: string list) (vars : string VarMap.t)
    (types : (string * string) list VarMap.t) : Scope.t =
  match ast.desc with
  | BinaryOperator { lhs; rhs; kind } -> (
      let op_type = parse_op_type lhs vars in
      match kind with
      | Assign -> (
          match (is_array_subscript lhs) with 
          | true -> 
            let name = get_array_name lhs in
            let index = get_array_index lhs in
            ("", vars, types) |> Scope.add_string @@ "let " ^ name ^ " = set_at_index " ^ name ^ " " ^ index ^ "( " 
            |> Scope.extend ~f:(visit_expr rhs mutated_vars)
            |> Scope.add_string ") in\n"
          | false -> 
            ("", vars, types) |> Scope.add_string "let "
            |> Scope.extend ~f:(visit_expr lhs mutated_vars)
            |> Scope.add_string " = "
            |> Scope.extend ~f:(visit_expr rhs mutated_vars)
            |> Scope.add_string " in\n" )
      | _ -> 
        ("", vars, types)
        |> Scope.add_string (parse_binary_operator kind op_type ^ " ")
        |> Scope.extend ~f:(visit_expr lhs mutated_vars)
        |> Scope.extend ~f:(visit_expr rhs mutated_vars))
  | UnaryOperator { kind; operand; _ } -> (
      match kind with
      | PostInc ->
          ("", vars, types) |> Scope.add_string "let "
          |> Scope.extend ~f:(visit_expr operand mutated_vars)
          |> Scope.add_string " = "
          |> Scope.extend ~f:(visit_expr operand mutated_vars)
          |> Scope.add_string " + 1 in\n"
      | PostDec ->
          ("", vars, types) |> Scope.add_string "let "
          |> Scope.extend ~f:(visit_expr operand mutated_vars)
          |> Scope.add_string " = "
          |> Scope.extend ~f:(visit_expr operand mutated_vars)
          |> Scope.add_string " - 1 in\n"
      | _ -> failwith "Unrecognized Unary Operator")
  | ArraySubscript {base;index; _} ->
    let name = Collect_vars.get_expr_names base in
    let stringIndex = get_array_index ast in
    ("", vars, types) |> Scope.add_string @@ "(List.nth_exn " ^ name ^ " " ^ stringIndex ^ ") "
  | DeclRef d -> (
      match d.name with
      | IdentifierName name -> ("", vars, types) |> Scope.add_string (name ^ " ")
      | _ -> assert false)
  | IntegerLiteral i -> (
      match i with
      | Int value ->
          ("", vars, types) |> Scope.add_string (Int.to_string value ^ " ")
      | _ -> assert false)
  | FloatingLiteral f -> (
      match f with
      | Float value ->
          let float_str = Float.to_string value in
          ("", vars, types)
          |> Scope.add_string
               (float_str
               ^ (if String.contains float_str '.' then "" else ".")
               ^ " ")
      | _ -> assert false)
  | CharacterLiteral { value; _ } ->
      ("", vars, types)
      |> Scope.add_string
           ("'" ^ (String.of_char @@ Char.of_int_exn value) ^ "' ")
  | Member s -> ("", vars, types) |> Scope.add_string @@ parse_struct_expr ast
  | Call { callee; args } -> (
      match List.length args with
      | 0 ->
          ("", vars, types)
          |> Scope.extend ~f:(visit_expr callee mutated_vars)
          |> Scope.add_string "();"
      | _ ->
          ("", vars, types) |> Scope.add_string "("
          |> Scope.extend ~f:(visit_expr callee mutated_vars)
          |> (fun s ->
               List.fold ~init:s
                 ~f:(fun s arg ->
                   Scope.aggregate s
                   @@ visit_expr arg mutated_vars (Scope.get_vars s) (Scope.get_types s))
                 args)
          |> Scope.add_string ")")
  | _ ->
      Clang.Printer.expr Format.std_formatter ast;
      ("", vars, types)

let parse (source : string) : string =
  let ast = Clang.Ast.parse_string source in
  Scope.get_string
    (List.fold ~init:Scope.empty
       ~f:(fun s item ->
         Scope.aggregate s
         @@ visit_decl item [] (Scope.get_vars s) (Scope.get_types s))
       ast.desc.items)

(* see .ml file for purpose of each function*)
val collect_mutated_vars : Clang.Ast.stmt -> string list -> string list
val get_decl_names : Clang.Ast.decl -> string
val get_expr_names : Clang.Ast.expr -> string

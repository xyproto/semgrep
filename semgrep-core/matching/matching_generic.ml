(*s: semgrep/matching/matching_generic.ml *)
(*s: pad/r2c copyright *)
(* Yoann Padioleau
 *
 * Copyright (C) 2019-2020 r2c
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)
(*e: pad/r2c copyright *)
open Common

module A = Ast_generic
module B = Ast_generic
module MV = Metavars_generic
module Lib = Lib_ast
module Ast = Ast_generic
module Flag = Flag_semgrep

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* Helper types and functions for generic_vs_generic.ml.
 * See generic_vs_generic.ml top comment for more information.
 *
 * todo:
 *  - factorize code in m_list__in_any_order at some point:
 *     * m_list__m_field 
 *     * m_list__m_attribute
 *     * m_list__m_xml_attr
 *     * m_list__m_argument (harder)
 *
 *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

(* ------------------------------------------------------------------------*)
(* Combinators history *) 
(* ------------------------------------------------------------------------*)
(*
 * version0: 
 *   type ('a, 'b) matcher = 'a -> 'b -> bool
 * 
 *   This just lets you know if you matched something.
 * 
 * version1:
 *   type ('a, 'b) matcher = 'a -> 'b -> unit -> ('a, 'b) option
 * 
 *   The Maybe monad.
 * 
 * version2:
 *   type ('a, 'b) matcher = 'a -> 'b -> binding -> binding list
 * 
 *   Why not returning a binding option ? because we need sometimes
 *   to return multiple possible bindings for one matching code.
 *   For instance with the pattern do 'f(..., $X, ...)', $X could be binded
 *   to different parts of the code.
 * 
 *   Note that the empty list means a match failure.
 *
 * version3:
 *   type ('a, 'b) matcher = 'a -> 'b -> tin -> ('a,'b) tout
 * 
 * version4: back to simpler
 *   type ('a, 'b) matcher = 'a -> 'b -> tin -> tout
 *)

(*s: type [[Matching_generic.tin]] *)
(* tin is for 'type in' and tout for 'type out' *)
(* incoming environment *)
type tin = Metavars_generic.metavars_binding
(*e: type [[Matching_generic.tin]] *)
(*s: type [[Matching_generic.tout]] *)
(* list of possible outcoming matching environments *)
type tout = tin list
(*e: type [[Matching_generic.tout]] *)

(*s: type [[Matching_generic.matcher]] *)
(* A matcher is something taking an element A and an element B
 * (for this module A will be the AST of the pattern and B
 * the AST of the program we want to match over), then some environment
 * information tin, and it will return something (tout) that will
 * represent a match between element A and B.
 *)
(* currently 'a and 'b are usually the same type as we use the
 * same language for the host language and pattern language 
 *)
type ('a, 'b) matcher = 'a -> 'b -> tin -> tout
(*e: type [[Matching_generic.matcher]] *)

(*****************************************************************************)
(* Globals *)
(*****************************************************************************)


(*****************************************************************************)
(* Debugging *)
(*****************************************************************************)
(*s: function [[Matching_generic.str_of_any]] *)
let str_of_any any = 
  if !Flag.debug && !Flag.debug_with_full_position
  then Meta_parse_info._current_precision :=
    { Meta_parse_info.default_dumper_precision with Meta_parse_info.
      full_info = true };

  let v = Meta_ast.vof_any any in
  let s = Ocaml.string_of_v v in
  s
(*e: function [[Matching_generic.str_of_any]] *)

(*****************************************************************************)
(* Monadic operators *)
(*****************************************************************************)
(* The >>= combinator below allow you to configure the matching process
 * anyway you want. Essentially this combinator takes a matcher,
 * another matcher, and returns a matcher that combines the 2
 * matcher arguments.
 *
 * In the case of a simple boolean matcher, you just need to write:
 *
 *   let (>>=) m1 m2 = fun tin ->
 *    match m1 tin with
 *    | None -> None
 *    | Some x ->
 *        m2 x tin
 *
 * For more context, this tutorial on monads in OCaml can be useful:
 * https://www.cs.cornell.edu/courses/cs3110/2019sp/textbook/ads/ex_maybe_monad.html
 *)

(*s: function [[Matching_generic.monadic_bind]] *)
let ((>>=):
  (tin -> tout) ->
  (unit -> (tin -> tout)) ->
  (tin -> tout)) = fun m1 m2 ->
  fun tin ->
    (* let's get a list of possible environment match (could be 
     * the empty list when it didn't match, playing the role None
     * had before)
     *)
    let xs = m1 tin in
    (* try m2 on each possible returned bindings *)
    let xxs = xs |> List.map (fun binding -> 
      m2 () binding
    ) in
    List.flatten xxs
(*e: function [[Matching_generic.monadic_bind]] *)

(*s: function [[Matching_generic.monadic_or]] *)
(* the disjunctive combinator *)
let ((>||>) :
  (tin -> tout) ->
  (tin -> tout) ->
  (tin -> tout)) = fun m1 m2 -> fun tin ->
(* CHOICE
      let xs = m1 tin in
      if null xs
      then m2 tin
      else xs
*)
    (* opti? use set instead of list *)
    m1 tin @ m2 tin
(*e: function [[Matching_generic.monadic_or]] *)

(*s: function [[Matching_generic.monadic_if_fail]] *)
(* the if-fail combinator *)
let (>!>) m1 else_cont = fun tin ->
  match m1 tin with
  | [] -> (else_cont ()) tin
  | xs -> xs
(*e: function [[Matching_generic.monadic_if_fail]] *)

(*s: function [[Matching_generic.return]] *)
(* The classical monad combinators *)
let (return : tin -> tout) = fun tin ->
[tin]
(*e: function [[Matching_generic.return]] *)

(*s: function [[Matching_generic.fail]] *)
let (fail : tin -> tout) = fun _tin ->
  if !Flag.debug
  then failwith "Generic_vs_generic.fail: Match failure"
  else
  []
(*e: function [[Matching_generic.fail]] *)
      
(*****************************************************************************)
(* Environment *)
(*****************************************************************************)

(*s: function [[Matching_generic.equal_ast_binded_code]] *)
(* pre: both 'a' and 'b' contains only regular code; there are no
 * metavariables inside them.
 *)
let equal_ast_binded_code (a: Ast.any) (b: Ast.any) : bool =
  match a, b with
  | A.I _, A.I _
  | A.N _, A.N _
  | A.E _, A.E _ 
  | A.P _, A.P _ 
  | A.S _, A.S _
  | A.T _, A.T _
    ->
      (* Note that because we want to retain the position information
       * of the matched code in the environment (e.g. for the -pvar
       * sgrep command line argument), we can not just use the
       * generic '=' OCaml operator as 'a' and 'b' may represent
       * the same code but they will contain leaves in their AST
       * with different position information. So before doing
       * the comparison we just need to remove/abstract-away 
       * the line number information in each ASTs.
       *)
      let a = Lib.abstract_position_info_any a in
      let b = Lib.abstract_position_info_any b in
      let res = a =*= b in
      if !Flag.verbose && not res
      then begin
        pr2 (spf "A = %s" (str_of_any a));
        pr2 (spf "B = %s" (str_of_any b));
      end;
      res

  | _, _ -> 
      false
(*e: function [[Matching_generic.equal_ast_binded_code]] *)

(*s: function [[Matching_generic.check_and_add_metavar_binding]] *)
let check_and_add_metavar_binding((mvar:MV.mvar), valu) = fun tin ->
  match Common2.assoc_opt mvar tin with
  | Some valu' ->
      (* Should we use generic_vs_generic itself for comparing the code?
       * Hmmm, we can't because it leads to a circular dependencies.
       * Moreover here we know both valu and valu' are regular code,
       * not patterns, so we can just use the generic '=' of OCaml.
       *)
      if equal_ast_binded_code valu valu'
      then Some tin (* valu remains the metavar witness *)
      else None
  | None ->
      (* first time the metavar is binded, just add it to the environment *)
      Some (Common2.insert_assoc (mvar, valu) tin)
(*e: function [[Matching_generic.check_and_add_metavar_binding]] *)

(*s: function [[Matching_generic.envf]] *)
let (envf: (MV.mvar Ast.wrap, Ast.any) matcher) =
 fun (mvar, _imvar) any  -> fun tin ->
  match check_and_add_metavar_binding (mvar, any) tin with
  | None ->
      if !Flag.verbose 
      then pr2 (spf "envf: fail, %s (%s)" mvar (str_of_any any));
      fail tin
  | Some new_binding ->
      if !Flag.verbose 
      then pr2 (spf "envf: success, %s (%s)" mvar (str_of_any any));
      return new_binding
(*e: function [[Matching_generic.envf]] *)

(*s: function [[Matching_generic.empty_environment]] *)
let empty_environment () = []
(*e: function [[Matching_generic.empty_environment]] *)

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

(*s: function [[Matching_generic.has_ellipsis_stmts]] *)
(* guard for deep stmt matching *)
let has_ellipsis_stmts xs = 
  xs |> List.exists (function
    | A.ExprStmt (A.Ellipsis _) -> true
    | _ -> false
  )
(*e: function [[Matching_generic.has_ellipsis_stmts]] *)

(*s: function [[Matching_generic.all_elem_and_rest_of_list]] *)
(* todo? optimize, probably not the optimal version ... *)
let all_elem_and_rest_of_list xs =
  let xs = Common.index_list xs |> List.map (fun (x, i) -> (i, x)) in
  xs |> List.map (fun (i, x) -> x, List.remove_assq i xs |> List.map snd)
(*e: function [[Matching_generic.all_elem_and_rest_of_list]] *)

(*s: toplevel [[Matching_generic._1]] *)
let _ = Common2.example
  (all_elem_and_rest_of_list ['a';'b';'c'] =
    [('a', ['b';'c']); ('b', ['a';'c']); ('c', ['a';'b'])])
(*e: toplevel [[Matching_generic._1]] *)

(*s: function [[Matching_generic.return_bis]] *)
let return () = return
(*e: function [[Matching_generic.return_bis]] *)
(*s: function [[Matching_generic.fail_bis]] *)
let fail () = fail
(*e: function [[Matching_generic.fail_bis]] *)

(*s: constant [[Matching_generic.regexp_regexp_string]] *)
let regexp_regexp_string = "^=~/\\(.*\\)/$"
(*e: constant [[Matching_generic.regexp_regexp_string]] *)
(*s: function [[Matching_generic.is_regexp_string]] *)
let is_regexp_string s =
 s =~ regexp_regexp_string
(*e: function [[Matching_generic.is_regexp_string]] *)
(*s: function [[Matching_generic.regexp_of_regexp_string]] *)
let regexp_of_regexp_string s = 
  if s =~ regexp_regexp_string
  then 
    let x = Common.matched1 s in
(* TODO
      let rex = Pcre.regexp s in
      if Pcre.pmatch ~rex sb
*)
    Str.regexp x 
  else
    failwith (spf "This is not a regexp_string: " ^ s)
(*e: function [[Matching_generic.regexp_of_regexp_string]] *)

(*****************************************************************************)
(* Generic matchers *)
(*****************************************************************************)

(* ---------------------------------------------------------------------- *)
(* stdlib: option *)
(* ---------------------------------------------------------------------- *)
(*s: function [[Matching_generic.m_option]] *)
let (m_option: ('a,'b) matcher -> ('a option,'b option) matcher) = fun f a b ->
  match a, b with
  | None, None -> return ()
  | Some xa, Some xb ->
      f xa xb 
  | None, _
  | Some _, _
      -> fail ()
(*e: function [[Matching_generic.m_option]] *)

(*s: function [[Matching_generic.m_option_ellipsis_ok]] *)
(* dots: *)
let m_option_ellipsis_ok f a b = 
  match a, b with
  | None, None -> return ()

  (* dots: ... can match 0 or 1 expression *)
  | Some (A.Ellipsis _), None -> return ()

  | Some xa, Some xb ->
      f xa xb 
  | None, _
  | Some _, _
      -> fail ()
(*e: function [[Matching_generic.m_option_ellipsis_ok]] *)

(*s: function [[Matching_generic.m_option_none_can_match_some]] *)
(* less-is-ok: *)
let m_option_none_can_match_some f a b =
  match a, b with
  (* Nothing specified in the pattern can match Some stuff *)
  | None, _ -> return ()

  | Some xa, Some xb ->
      f xa xb 
  | Some _, _
      -> fail ()
(*e: function [[Matching_generic.m_option_none_can_match_some]] *)

(* ---------------------------------------------------------------------- *)
(* stdlib: ref *)
(* ---------------------------------------------------------------------- *)
(*s: function [[Matching_generic.m_ref]] *)
let (m_ref: ('a,'b) matcher -> ('a ref,'b ref) matcher) = fun f a b ->
  match a, b with
  { contents = xa}, { contents = xb} ->
    f xa xb 
(*e: function [[Matching_generic.m_ref]] *)

(* ---------------------------------------------------------------------- *)
(* stdlib: list *)
(* ---------------------------------------------------------------------- *)

(*s: function [[Matching_generic.m_list]] *)
let rec m_list f a b =
  match a, b with
  | [], [] ->
      return ()
  | xa::aas, xb::bbs ->
      f xa xb >>= (fun () ->
      m_list f aas bbs 
      )
  | [], _
  | _::_, _ ->
      fail ()
(*e: function [[Matching_generic.m_list]] *)

(*s: function [[Matching_generic.m_list_prefix]] *)
let rec m_list_prefix f a b =
  match a, b with
  | [], [] ->
      return ()
  | xa::aas, xb::bbs ->
      f xa xb >>= (fun () ->
      m_list_prefix f aas bbs 
      )
  | [], _ -> return ()
  | _::_, _ ->
      fail ()
(*e: function [[Matching_generic.m_list_prefix]] *)

(*s: function [[Matching_generic.m_list_with_dots]] *)
let rec m_list_with_dots f is_dots less_is_ok xsa xsb =
    match xsa, xsb with
  | [], [] ->
      return ()

  (* less-is-ok: empty list can sometimes match non-empty list *)
  | [], _::_ when less_is_ok -> 
    return ()

  (* dots: '...', can also match no argument *)
  | [a], []  when is_dots a ->
      return ()

  | (a)::xsa, xb::xsb when is_dots a ->
      (* can match nothing *)
      (m_list_with_dots f is_dots less_is_ok xsa (xb::xsb)) >||>
      (* can match more *)
      (m_list_with_dots f is_dots less_is_ok (a::xsa) xsb)

  (* the general case *)
  | xa::aas, xb::bbs ->
      f xa xb >>= (fun () ->
      m_list_with_dots f is_dots less_is_ok aas bbs 
      )
  | [], _
  | _::_, _ ->
      fail ()
(*e: function [[Matching_generic.m_list_with_dots]] *)

(* ---------------------------------------------------------------------- *)
(* stdlib: bool/int/string/... *)
(* ---------------------------------------------------------------------- *)

(*s: function [[Matching_generic.m_bool]] *)
let m_bool a b = 
  if a = b then return () else fail ()
(*e: function [[Matching_generic.m_bool]] *)

(*s: function [[Matching_generic.m_int]] *)
let m_int a b = 
  if a =|= b then return () else fail ()
(*e: function [[Matching_generic.m_int]] *)

(*s: function [[Matching_generic.m_string]] *)
let m_string a b =
  if a =$= b then return () else fail ()
(*e: function [[Matching_generic.m_string]] *)

(*s: function [[Matching_generic.string_is_prefix]] *)
let string_is_prefix s1 s2 =
  let len1 = String.length s1
  and len2 = String.length s2 in
  if len1 < len2 then false else
    let sub = String.sub s1 0 len2 in
    (sub = s2)
(*e: function [[Matching_generic.string_is_prefix]] *)

(*s: function [[Matching_generic.m_string_prefix]] *)
(* less-is-ok: *)
let m_string_prefix a b =
  if string_is_prefix b a then return () else fail ()
(*e: function [[Matching_generic.m_string_prefix]] *)

(* ---------------------------------------------------------------------- *)
(* Token *)
(* ---------------------------------------------------------------------- *)

(*s: function [[Matching_generic.m_info]] *)
(* we do not care about position! or differences in space/indent/comment!
 * so we can just  'return ()'
 *)
let m_info _a _b = return ()
(*e: function [[Matching_generic.m_info]] *)

(*s: function [[Matching_generic.m_tok]] *)
let m_tok a b = m_info a b
(*e: function [[Matching_generic.m_tok]] *)

(*s: function [[Matching_generic.m_wrap]] *)
let m_wrap f a b =
  match a, b with
  ((xaa, ainfo), (xbb, binfo)) ->
    f xaa xbb >>= (fun () ->
    m_info ainfo binfo 
    )
(*e: function [[Matching_generic.m_wrap]] *)

(*s: function [[Matching_generic.m_bracket]] *)
let m_bracket f (a1, a2, a3) (b1, b2, b3) = 
   m_info a1 b1 >>= (fun () ->
   f a2 b2 >>= (fun () ->
   m_info a3 b3
   ))
(*e: function [[Matching_generic.m_bracket]] *)

(* ---------------------------------------------------------------------- *)
(* Misc *)
(* ---------------------------------------------------------------------- *)

(*s: function [[Matching_generic.m_other_xxx]] *)
let m_other_xxx a b = 
  match a, b with
  | a, b when a =*= b -> return ()
  | _ -> fail ()
(*e: function [[Matching_generic.m_other_xxx]] *)
(*e: semgrep/matching/matching_generic.ml *)

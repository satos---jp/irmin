(*
 * Copyright (c) 2013-2021 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open! Import
include Store_intf
open Merge.Infix

let src = Logs.Src.create "irmin" ~doc:"Irmin branch-consistent store"

module Log = (val Logs.src_log src : Logs.LOG)

module Make (P : Private.S) = struct
  module Schema = P.Schema
  module Metadata = P.Node.Metadata
  module Hash = P.Hash
  module Branch_store = P.Branch
  module Key = P.Node.Path
  module OCamlGraph = Graph
  module Nodes = Node.Graph (P.Node)
  module Commits = Commit.History (P.Commit)
  module Graph = Object_graph.Make (Hash) (Branch_store.Key)
  module Private = P
  module Info = P.Commit.Info

  module Contents = struct
    include P.Contents.Val

    let of_hash r h = P.Contents.find (P.Repo.contents_t r) h
    let hash c = P.Contents.Key.hash c
  end

  module Tree = struct
    include Tree.Make (P)

    let of_hash r h = import r h
    let shallow r h = import_no_check r h

    let hash : t -> hash =
     fun tr -> match hash tr with `Node h -> h | `Contents (h, _) -> h
  end

  type branch = P.Branch.Key.t [@@deriving irmin]
  type hash = Hash.t [@@deriving irmin]
  type node = Tree.node [@@deriving irmin]
  type contents = Contents.t [@@deriving irmin]
  type metadata = Metadata.t [@@deriving irmin]
  type tree = Tree.t [@@deriving irmin]
  type key = Key.t [@@deriving irmin]
  type slice = P.Slice.t [@@deriving irmin]
  type step = Key.step [@@deriving irmin]
  type info = P.Commit.Info.t [@@deriving irmin]
  type repo = P.Repo.t
  type commit = { r : repo; h : Hash.t; v : P.Commit.value }
  type head_ref = [ `Branch of branch | `Head of commit option ref ]
  type watch = unit -> unit Lwt.t
  type Remote.t += E of P.Remote.endpoint
  type lca_error = [ `Max_depth_reached | `Too_many_lcas ] [@@deriving irmin]
  type ff_error = [ `Rejected | `No_change | lca_error ]

  type write_error =
    [ Merge.conflict | `Too_many_retries of int | `Test_was of tree option ]

  (* The deriver does not work here because of it cannot derive the
     [Merge.conflit] inheritance. *)
  let write_error_t =
    let open Type in
    variant "write-error" (fun c m e -> function
      | `Conflict x -> c x | `Too_many_retries x -> m x | `Test_was x -> e x)
    |~ case1 "conflict" string (fun x -> `Conflict x)
    |~ case1 "too-many-retries" int (fun x -> `Too_many_retries x)
    |~ case1 "test-got" (option tree_t) (fun x -> `Test_was x)
    |> sealv

  (* The deriver does not work here because of it cannot derive the
     [lca_error[ inheritance. *)
  let ff_error_t =
    Type.enum "ff-error"
      [
        ("max-depth-reached", `Max_depth_reached);
        ("too-many-lcas", `Too_many_lcas);
        ("no-change", `No_change);
        ("rejected", `Rejected);
      ]

  let equal_hash = Type.(unstage (equal Hash.t))
  let equal_contents = Type.(unstage (equal Contents.t))
  let equal_branch = Type.(unstage (equal Branch_store.Key.t))
  let pp_key = Type.pp Key.t
  let pp_hash = Type.pp Hash.t
  let pp_branch = Type.pp Branch_store.Key.t
  let pp_int = Type.pp Type.int
  let pp_tree = Type.(pp Tree.t)
  let compare_hash = Type.(unstage (compare P.Hash.t))
  let save_contents b c = P.Contents.add b c

  let save_tree ?(clear = true) r x y (tr : Tree.t) =
    match Tree.destruct tr with
    | `Contents (c, _) ->
        let* c = Tree.Contents.force_exn c in
        save_contents x c
    | `Node n -> Tree.export ~clear r x y n

  module Hashes = Set.Make (struct
    type t = P.Hash.t

    let compare = compare_hash
  end)

  module Commit = struct
    type t = commit

    let t r =
      let open Type in
      record "commit" (fun h v -> { r; h; v })
      |+ field "hash" Hash.t (fun t -> t.h)
      |+ field "value" P.Commit.Val.t (fun t -> t.v)
      |> sealr

    let v r ~info ~parents tree =
      P.Repo.batch r @@ fun contents_t node_t commit_t ->
      let* node =
        match Tree.destruct tree with
        | `Node t -> Tree.export r contents_t node_t t
        | `Contents _ -> Lwt.fail_invalid_arg "cannot add contents at the root"
      in
      let v = P.Commit.Val.v ~info ~node ~parents in
      let+ h = P.Commit.add commit_t v in
      { r; h; v }

    let node t = P.Commit.Val.node t.v
    let tree t = Tree.import_no_check t.r (`Node (node t))
    let equal x y = equal_hash x.h y.h
    let hash t = t.h
    let info t = P.Commit.Val.info t.v
    let parents t = P.Commit.Val.parents t.v
    let pp_hash ppf t = pp_hash ppf t.h

    let of_hash r h =
      P.Commit.find (P.Repo.commit_t r) h >|= function
      | None -> None
      | Some v -> Some { r; h; v }

    let to_private_commit t = t.v

    let of_private_commit r v =
      let h = P.Commit.Key.hash v in
      { r; h; v }

    let equal_opt x y =
      match (x, y) with
      | None, None -> true
      | Some x, Some y -> equal x y
      | _ -> false
  end

  let to_private_node = Tree.to_private_node
  let of_private_node = Tree.of_private_node
  let to_private_commit = Commit.to_private_commit
  let of_private_commit = Commit.of_private_commit
  let unwatch w = w ()

  module Repo = struct
    type t = repo

    type elt =
      [ `Commit of Hash.t
      | `Node of Hash.t
      | `Contents of Hash.t
      | `Branch of P.Branch.Key.t ]
    [@@deriving irmin]

    let v = P.Repo.v
    let close = P.Repo.close
    let branch_t t = P.Repo.branch_t t
    let commit_t t = P.Repo.commit_t t
    let node_t t = P.Repo.node_t t
    let contents_t t = P.Repo.contents_t t
    let branches t = P.Branch.list (branch_t t)

    let heads repo =
      let t = branch_t repo in
      let* bs = Branch_store.list t in
      Lwt_list.fold_left_s
        (fun acc r ->
          Branch_store.find t r >>= function
          | None -> Lwt.return acc
          | Some h -> (
              Commit.of_hash repo h >|= function
              | None -> acc
              | Some h -> h :: acc))
        [] bs

    let export ?(full = true) ?depth ?(min = []) ?(max = `Head) t =
      Log.debug (fun f ->
          f "export depth=%s full=%b min=%d max=%s"
            (match depth with None -> "<none>" | Some d -> string_of_int d)
            full (List.length min)
            (match max with
            | `Head -> "heads"
            | `Max m -> string_of_int (List.length m)));
      let* max = match max with `Head -> heads t | `Max m -> Lwt.return m in
      let* slice = P.Slice.empty () in
      let max = List.map (fun x -> `Commit x.h) max in
      let min = List.map (fun x -> `Commit x.h) min in
      let pred = function
        | `Commit k ->
            let+ parents = Commits.parents (commit_t t) k in
            List.map (fun x -> `Commit x) parents
        | _ -> Lwt.return_nil
      in
      let* g = Graph.closure ?depth ~pred ~min ~max () in
      let keys =
        List.fold_left
          (fun acc -> function `Commit c -> c :: acc | _ -> acc)
          [] (Graph.vertex g)
      in
      let root_nodes = ref [] in
      let* () =
        Lwt_list.iter_p
          (fun k ->
            P.Commit.find (commit_t t) k >>= function
            | None -> Lwt.return_unit
            | Some c ->
                root_nodes := P.Commit.Val.node c :: !root_nodes;
                P.Slice.add slice (`Commit (k, c)))
          keys
      in
      if not full then Lwt.return slice
      else
        (* XXX: we can compute a [min] if needed *)
        let* nodes = Nodes.closure (node_t t) ~min:[] ~max:!root_nodes in
        let contents = ref Hashes.empty in
        let* () =
          Lwt_list.iter_p
            (fun k ->
              P.Node.find (node_t t) k >>= function
              | None -> Lwt.return_unit
              | Some v ->
                  List.iter
                    (function
                      | _, `Contents (c, _) ->
                          contents := Hashes.add c !contents
                      | _ -> ())
                    (P.Node.Val.list v);
                  P.Slice.add slice (`Node (k, v)))
            nodes
        in
        let+ () =
          Lwt_list.iter_p
            (fun k ->
              P.Contents.find (contents_t t) k >>= function
              | None -> Lwt.return_unit
              | Some m -> P.Slice.add slice (`Contents (k, m)))
            (Hashes.elements !contents)
        in
        slice

    exception Import_error of string

    let import_error fmt = Fmt.kstrf (fun x -> Lwt.fail (Import_error x)) fmt

    let import t s =
      let aux name add (k, v) =
        let* k' = add v in
        if not (equal_hash k k') then
          import_error "%s import error: expected %a, got %a" name pp_hash k
            pp_hash k'
        else Lwt.return_unit
      in
      let contents = ref [] in
      let nodes = ref [] in
      let commits = ref [] in
      let* () =
        P.Slice.iter s (function
          | `Contents c ->
              contents := c :: !contents;
              Lwt.return_unit
          | `Node n ->
              nodes := n :: !nodes;
              Lwt.return_unit
          | `Commit c ->
              commits := c :: !commits;
              Lwt.return_unit)
      in
      P.Repo.batch t @@ fun contents_t node_t commit_t ->
      Lwt.catch
        (fun () ->
          let* () =
            Lwt_list.iter_p
              (aux "Contents" (P.Contents.add contents_t))
              !contents
          in
          Lwt_list.iter_p (aux "Node" (P.Node.add node_t)) !nodes >>= fun () ->
          let+ () =
            Lwt_list.iter_p (aux "Commit" (P.Commit.add commit_t)) !commits
          in
          Ok ())
        (function
          | Import_error e -> Lwt.return (Error (`Msg e))
          | e -> Fmt.kstrf Lwt.fail_invalid_arg "impot error: %a" Fmt.exn e)

    let ignore_lwt _ = Lwt.return_unit
    let return_false _ = Lwt.return false
    let default_pred_contents _ _ = Lwt.return []

    let default_pred_node t k =
      P.Node.find (node_t t) k >|= function
      | None -> []
      | Some v ->
          List.rev_map
            (function
              | _, `Node n -> `Node n | _, `Contents (c, _) -> `Contents c)
            (P.Node.Val.list v)

    let default_pred_commit t c =
      P.Commit.find (commit_t t) c >|= function
      | None ->
          Log.debug (fun l -> l "%a: not found" pp_hash c);
          []
      | Some c ->
          let node = P.Commit.Val.node c in
          let parents = P.Commit.Val.parents c in
          [ `Node node ] @ List.map (fun k -> `Commit k) parents

    let default_pred_branch t b =
      P.Branch.find (branch_t t) b >|= function
      | None ->
          Log.debug (fun l -> l "%a: not found" pp_branch b);
          []
      | Some b -> [ `Commit b ]

    let iter ?cache_size ~min ~max ?edge ?(branch = ignore_lwt)
        ?(commit = ignore_lwt) ?(node = ignore_lwt) ?(contents = ignore_lwt)
        ?(skip_branch = return_false) ?(skip_commit = return_false)
        ?(skip_node = return_false) ?(skip_contents = return_false)
        ?(pred_branch = default_pred_branch)
        ?(pred_commit = default_pred_commit) ?(pred_node = default_pred_node)
        ?(pred_contents = default_pred_contents) ?(rev = true) t =
      let node = function
        | `Commit x -> commit x
        | `Node x -> node x
        | `Contents x -> contents x
        | `Branch x -> branch x
      in
      let skip = function
        | `Commit x -> skip_commit x
        | `Node x -> skip_node x
        | `Contents x -> skip_contents x
        | `Branch x -> skip_branch x
      in
      let pred = function
        | `Commit x -> pred_commit t x
        | `Node x -> pred_node t x
        | `Contents x -> pred_contents t x
        | `Branch x -> pred_branch t x
      in
      Graph.iter ?cache_size ~pred ~min ~max ~node ?edge ~skip ~rev ()

    let breadth_first_traversal ?cache_size ~max ?(branch = ignore_lwt)
        ?(commit = ignore_lwt) ?(node = ignore_lwt) ?(contents = ignore_lwt)
        ?(pred_branch = default_pred_branch)
        ?(pred_commit = default_pred_commit) ?(pred_node = default_pred_node)
        ?(pred_contents = default_pred_contents) t =
      let node = function
        | `Commit x -> commit x
        | `Node x -> node x
        | `Contents x -> contents x
        | `Branch x -> branch x
      in
      let pred = function
        | `Commit x -> pred_commit t x
        | `Node x -> pred_node t x
        | `Contents x -> pred_contents t x
        | `Branch x -> pred_branch t x
      in
      Graph.breadth_first_traversal ?cache_size ~pred ~max ~node ()
  end

  type t = {
    repo : Repo.t;
    head_ref : head_ref;
    mutable tree : (commit * tree) option;
    (* cache for the store tree *)
    lock : Lwt_mutex.t;
  }

  let repo t = t.repo
  let branch_store t = Repo.branch_t t.repo
  let commit_store t = Repo.commit_t t.repo

  let status t =
    match t.head_ref with
    | `Branch b -> `Branch b
    | `Head h -> ( match !h with None -> `Empty | Some c -> `Commit c)

  let head_ref t =
    match t.head_ref with
    | `Branch t -> `Branch t
    | `Head h -> ( match !h with None -> `Empty | Some h -> `Head h)

  let branch t =
    match head_ref t with
    | `Branch t -> Lwt.return_some t
    | `Empty | `Head _ -> Lwt.return_none

  let err_no_head s = Fmt.kstrf Lwt.fail_invalid_arg "Irmin.%s: no head" s

  let retry_merge name fn =
    let rec aux i =
      fn () >>= function
      | Error _ as c -> Lwt.return c
      | Ok true -> Merge.ok ()
      | Ok false ->
          Log.debug (fun f -> f "Irmin.%s: conflict, retrying (%d)." name i);
          aux (i + 1)
    in
    aux 1

  let of_ref repo head_ref =
    let lock = Lwt_mutex.create () in
    Lwt.return { lock; head_ref; repo; tree = None }

  let err_invalid_branch t =
    let err = Fmt.strf "%a is not a valid branch name." pp_branch t in
    Lwt.fail (Invalid_argument err)

  let of_branch repo id =
    if Branch_store.Key.is_valid id then of_ref repo (`Branch id)
    else err_invalid_branch id

  let master repo = of_branch repo Branch_store.Key.master
  let empty repo = of_ref repo (`Head (ref None))
  let of_commit c = of_ref c.r (`Head (ref (Some c)))

  let skip_key key =
    Log.debug (fun l -> l "[watch-key] key %a has not changed" pp_key key);
    Lwt.return_unit

  let changed_key key old_t new_t =
    Log.debug (fun l ->
        let pp = Fmt.option ~none:(Fmt.any "<none>") pp_hash in
        let old_h = Option.map Tree.hash old_t in
        let new_h = Option.map Tree.hash new_t in
        l "[watch-key] key %a has changed: %a -> %a" pp_key key pp old_h pp
          new_h)

  let with_tree ~key x f =
    x >>= function
    | None -> skip_key key
    | Some x ->
        changed_key key None None;
        f x

  let lift_tree_diff ~key tree fn = function
    | `Removed x ->
        with_tree ~key (tree x) @@ fun v ->
        changed_key key (Some v) None;
        fn @@ `Removed (x, v)
    | `Added x ->
        with_tree ~key (tree x) @@ fun v ->
        changed_key key None (Some v);
        fn @@ `Added (x, v)
    | `Updated (x, y) -> (
        assert (not (Commit.equal x y));
        let* vx = tree x in
        let* vy = tree y in
        match (vx, vy) with
        | None, None -> skip_key key
        | None, Some vy ->
            changed_key key None (Some vy);
            fn @@ `Added (y, vy)
        | Some vx, None ->
            changed_key key (Some vx) None;
            fn @@ `Removed (x, vx)
        | Some vx, Some vy ->
            if Tree.equal vx vy then skip_key key
            else (
              changed_key key (Some vx) (Some vy);
              fn @@ `Updated ((x, vx), (y, vy))))

  let head t =
    let h =
      match head_ref t with
      | `Head key -> Lwt.return_some key
      | `Empty -> Lwt.return_none
      | `Branch name -> (
          Branch_store.find (branch_store t) name >>= function
          | None -> Lwt.return_none
          | Some h -> Commit.of_hash t.repo h)
    in
    let+ h = h in
    Log.debug (fun f -> f "Head.find -> %a" Fmt.(option Commit.pp_hash) h);
    h

  let tree_and_head t =
    head t >|= function
    | None -> None
    | Some h -> (
        match t.tree with
        | Some (o, t) when Commit.equal o h -> Some (o, t)
        | _ ->
            t.tree <- None;

            (* the tree cache needs to be invalidated *)
            let tree = Tree.import_no_check (repo t) (`Node (Commit.node h)) in
            t.tree <- Some (h, tree);
            Some (h, tree))

  let tree t =
    tree_and_head t >|= function
    | None -> Tree.empty
    | Some (_, tree) -> (tree :> tree)

  let lift_head_diff repo fn = function
    | `Removed x -> (
        Commit.of_hash repo x >>= function
        | None -> Lwt.return_unit
        | Some x -> fn (`Removed x))
    | `Updated (x, y) -> (
        let* x = Commit.of_hash repo x in
        let* y = Commit.of_hash repo y in
        match (x, y) with
        | None, None -> Lwt.return_unit
        | Some x, None -> fn (`Removed x)
        | None, Some y -> fn (`Added y)
        | Some x, Some y -> fn (`Updated (x, y)))
    | `Added x -> (
        Commit.of_hash repo x >>= function
        | None -> Lwt.return_unit
        | Some x -> fn (`Added x))

  let watch t ?init fn =
    branch t >>= function
    | None -> failwith "watch a detached head: TODO"
    | Some name0 ->
        let init =
          match init with
          | None -> None
          | Some head0 -> Some [ (name0, head0.h) ]
        in
        let+ id =
          Branch_store.watch (branch_store t) ?init (fun name head ->
              if equal_branch name0 name then lift_head_diff t.repo fn head
              else Lwt.return_unit)
        in
        fun () -> Branch_store.unwatch (branch_store t) id

  let watch_key t key ?init fn =
    Log.debug (fun f -> f "watch-key %a" pp_key key);
    let tree c = Tree.find_tree (Commit.tree c) key in
    watch t ?init (lift_tree_diff ~key tree fn)

  module Head = struct
    let list = Repo.heads
    let find = head

    let get t =
      find t >>= function None -> err_no_head "head" | Some k -> Lwt.return k

    let set t c =
      match t.head_ref with
      | `Head h ->
          h := Some c;
          Lwt.return_unit
      | `Branch name -> Branch_store.set (branch_store t) name c.h

    let test_and_set_unsafe t ~test ~set =
      match t.head_ref with
      | `Head head ->
          (* [head] is protected by [t.lock]. *)
          if Commit.equal_opt !head test then (
            head := set;
            Lwt.return_true)
          else Lwt.return_false
      | `Branch name ->
          let h = function None -> None | Some c -> Some c.h in
          Branch_store.test_and_set (branch_store t) name ~test:(h test)
            ~set:(h set)

    let test_and_set t ~test ~set =
      Lwt_mutex.with_lock t.lock (fun () -> test_and_set_unsafe t ~test ~set)

    let fast_forward t ?max_depth ?n new_head =
      let return x = if x then Ok () else Error (`Rejected :> ff_error) in
      find t >>= function
      | None -> test_and_set t ~test:None ~set:(Some new_head) >|= return
      | Some old_head -> (
          Log.debug (fun f ->
              f "fast-forward-head old=%a new=%a" Commit.pp_hash old_head
                Commit.pp_hash new_head);
          if Commit.equal new_head old_head then
            (* we only update if there is a change *)
            Lwt.return (Error `No_change)
          else
            Commits.lcas (commit_store t) ?max_depth ?n new_head.h old_head.h
            >>= function
            | Ok [ x ] when equal_hash x old_head.h ->
                (* we only update if new_head > old_head *)
                test_and_set t ~test:(Some old_head) ~set:(Some new_head)
                >|= return
            | Ok _ -> Lwt.return (Error `Rejected)
            | Error e -> Lwt.return (Error (e :> ff_error)))

    (* Merge two commits:
       - Search for common ancestors
       - Perform recursive 3-way merges *)
    let three_way_merge t ?max_depth ?n ~info c1 c2 =
      P.Repo.batch (repo t) @@ fun _ _ commit_t ->
      Commits.three_way_merge commit_t ?max_depth ?n ~info c1.h c2.h

    (* FIXME: we might want to keep the new commit in case of conflict,
         and use it as a base for the next merge. *)
    let merge ~into:t ~info ?max_depth ?n c1 =
      Log.debug (fun f -> f "merge_head");
      let aux () =
        let* head = head t in
        match head with
        | None -> test_and_set_unsafe t ~test:head ~set:(Some c1) >>= Merge.ok
        | Some c2 ->
            three_way_merge t ~info ?max_depth ?n c1 c2 >>=* fun c3 ->
            let* c3 = Commit.of_hash t.repo c3 in
            test_and_set_unsafe t ~test:head ~set:c3 >>= Merge.ok
      in
      Lwt_mutex.with_lock t.lock (fun () -> retry_merge "merge_head" aux)
  end

  (* Retry an operation until the optimistic lock is happy. Ensure
     that the operation is done at least once. *)
  let retry ~retries fn =
    let done_once = ref false in
    let rec aux i =
      if !done_once && i > retries then
        Lwt.return (Error (`Too_many_retries retries))
      else
        fn () >>= function
        | Ok true -> Lwt.return (Ok ())
        | Error e -> Lwt.return (Error e)
        | Ok false ->
            done_once := true;
            aux (i + 1)
    in
    aux 0

  let root_tree = function
    | `Node _ as n -> Tree.v n
    | `Contents _ -> assert false

  let add_commit t old_head ((c, _) as tree) =
    match t.head_ref with
    | `Head head ->
        Lwt_mutex.with_lock t.lock (fun () ->
            if not (Commit.equal_opt old_head !head) then Lwt.return_false
            else (
              (* [head] is protected by [t.lock] *)
              head := Some c;
              t.tree <- Some tree;
              Lwt.return_true))
    | `Branch name ->
        (* concurrent handlers and/or process can modify the
           branch. Need to check that we are still working on the same
           head. *)
        let test = match old_head with None -> None | Some c -> Some c.h in
        let set = Some c.h in
        let+ r = Branch_store.test_and_set (branch_store t) name ~test ~set in
        if r then t.tree <- Some tree;
        r

  let pp_write_error ppf = function
    | `Conflict e -> Fmt.pf ppf "Got a conflict: %s" e
    | `Too_many_retries i ->
        Fmt.pf ppf
          "Failure after %d attempts to retry the operation: Too many attempts."
          i
    | `Test_was t ->
        Fmt.pf ppf "Test-and-set failed: got %a when reading the store"
          Fmt.(Dump.option pp_tree)
          t

  let write_error e : ('a, write_error) result Lwt.t = Lwt.return (Error e)
  let err_test v = write_error (`Test_was v)

  type snapshot = {
    head : commit option;
    root : tree;
    tree : tree option;
    (* the subtree used by the transaction *)
    parents : commit list;
  }

  let snapshot t key =
    tree_and_head t >>= function
    | None ->
        Lwt.return { head = None; root = Tree.empty; tree = None; parents = [] }
    | Some (c, root) ->
        let root = (root :> tree) in
        let+ tree = Tree.find_tree root key in
        { head = Some c; root; tree; parents = [ c ] }

  let same_tree x y =
    match (x, y) with
    | None, None -> true
    | None, _ | _, None -> false
    | Some x, Some y -> Tree.equal x y

  (* Update the store with a new commit. Ensure the no commit becomes orphan
     in the process. *)
  let update ?(allow_empty = false) ~info ?parents t key merge_tree f =
    let* s = snapshot t key in
    (* this might take a very long time *)
    let* new_tree = f s.tree in
    (* if no change and [allow_empty = true] then, do nothing *)
    if same_tree s.tree new_tree && (not allow_empty) && s.head <> None then
      Lwt.return (Ok true)
    else
      merge_tree s.root key ~current_tree:s.tree ~new_tree >>= function
      | Error e -> Lwt.return (Error e)
      | Ok root ->
          let info = info () in
          let parents = match parents with None -> s.parents | Some p -> p in
          let parents = List.map Commit.hash parents in
          let* c = Commit.v (repo t) ~info ~parents root in
          let* r = add_commit t s.head (c, root_tree (Tree.destruct root)) in
          Lwt.return (Ok r)

  let ok x = Ok x

  let fail name = function
    | Ok x -> Lwt.return x
    | Error e -> Fmt.kstrf Lwt.fail_with "%s: %a" name pp_write_error e

  let set_tree_once root key ~current_tree:_ ~new_tree =
    match new_tree with
    | None -> Tree.remove root key >|= ok
    | Some tree -> Tree.add_tree root key tree >|= ok

  let set_tree ?(retries = 13) ?allow_empty ?parents ~info t k v =
    Log.debug (fun l -> l "set %a" pp_key k);
    retry ~retries @@ fun () ->
    update t k ?allow_empty ?parents ~info set_tree_once @@ fun _tree ->
    Lwt.return_some v

  let set_tree_exn ?retries ?allow_empty ?parents ~info t k v =
    set_tree ?retries ?allow_empty ?parents ~info t k v >>= fail "set_exn"

  let remove ?(retries = 13) ?allow_empty ?parents ~info t k =
    Log.debug (fun l -> l "debug %a" pp_key k);
    retry ~retries @@ fun () ->
    update t k ?allow_empty ?parents ~info set_tree_once @@ fun _tree ->
    Lwt.return_none

  let remove_exn ?retries ?allow_empty ?parents ~info t k =
    remove ?retries ?allow_empty ?parents ~info t k >>= fail "remove_exn"

  let set ?retries ?allow_empty ?parents ~info t k v =
    let v = Tree.of_contents v in
    set_tree t k ?retries ?allow_empty ?parents ~info v

  let set_exn ?retries ?allow_empty ?parents ~info t k v =
    set t k ?retries ?allow_empty ?parents ~info v >>= fail "set_exn"

  let test_and_set_tree_once ~test root key ~current_tree ~new_tree =
    match (test, current_tree) with
    | None, None -> set_tree_once root key ~new_tree ~current_tree
    | None, _ | _, None -> err_test current_tree
    | Some test, Some v ->
        if Tree.equal test v then set_tree_once root key ~new_tree ~current_tree
        else err_test current_tree

  let test_and_set_tree ?(retries = 13) ?allow_empty ?parents ~info t k ~test
      ~set =
    Log.debug (fun l -> l "test-and-set %a" pp_key k);
    retry ~retries @@ fun () ->
    update t k ?allow_empty ?parents ~info (test_and_set_tree_once ~test)
    @@ fun _tree -> Lwt.return set

  let test_and_set_tree_exn ?retries ?allow_empty ?parents ~info t k ~test ~set
      =
    test_and_set_tree ?retries ?allow_empty ?parents ~info t k ~test ~set
    >>= fail "test_and_set_tree_exn"

  let test_and_set ?retries ?allow_empty ?parents ~info t k ~test ~set =
    let test = Option.map Tree.of_contents test in
    let set = Option.map Tree.of_contents set in
    test_and_set_tree ?retries ?allow_empty ?parents ~info t k ~test ~set

  let test_and_set_exn ?retries ?allow_empty ?parents ~info t k ~test ~set =
    test_and_set ?retries ?allow_empty ?parents ~info t k ~test ~set
    >>= fail "test_and_set_exn"

  let merge_once ~old root key ~current_tree ~new_tree =
    let old = Merge.promise old in
    Merge.f (Merge.option Tree.merge) ~old current_tree new_tree >>= function
    | Ok tr -> set_tree_once root key ~new_tree:tr ~current_tree
    | Error e -> write_error (e :> write_error)

  let merge_tree ?(retries = 13) ?allow_empty ?parents ~info ~old t k tree =
    Log.debug (fun l -> l "merge %a" pp_key k);
    retry ~retries @@ fun () ->
    update t k ?allow_empty ?parents ~info (merge_once ~old) @@ fun _tree ->
    Lwt.return tree

  let merge_tree_exn ?retries ?allow_empty ?parents ~info ~old t k tree =
    merge_tree ?retries ?allow_empty ?parents ~info ~old t k tree
    >>= fail "merge_tree_exn"

  let merge ?retries ?allow_empty ?parents ~info ~old t k v =
    let old = Option.map Tree.of_contents old in
    let v = Option.map Tree.of_contents v in
    merge_tree ?retries ?allow_empty ?parents ~info ~old t k v

  let merge_exn ?retries ?allow_empty ?parents ~info ~old t k v =
    merge ?retries ?allow_empty ?parents ~info ~old t k v >>= fail "merge_exn"

  let mem t k = tree t >>= fun tree -> Tree.mem tree k
  let mem_tree t k = tree t >>= fun tree -> Tree.mem_tree tree k
  let find_all t k = tree t >>= fun tree -> Tree.find_all tree k
  let find t k = tree t >>= fun tree -> Tree.find tree k
  let get t k = tree t >>= fun tree -> Tree.get tree k
  let find_tree t k = tree t >>= fun tree -> Tree.find_tree tree k
  let get_tree t k = tree t >>= fun tree -> Tree.get_tree tree k

  let hash t k =
    find_tree t k >|= function
    | None -> None
    | Some tree -> Some (Tree.hash tree)

  let get_all t k = tree t >>= fun tree -> Tree.get_all tree k
  let list t k = tree t >>= fun tree -> Tree.list tree k
  let kind t k = tree t >>= fun tree -> Tree.kind tree k

  let with_tree ?(retries = 13) ?allow_empty ?parents
      ?(strategy = `Test_and_set) ~info t key f =
    let done_once = ref false in
    let rec aux n old_tree =
      Log.debug (fun l -> l "with_tree %a (%d/%d)" pp_key key n retries);
      if !done_once && n > retries then write_error (`Too_many_retries retries)
      else
        let* new_tree = f old_tree in
        match (strategy, new_tree) with
        | `Set, Some tree ->
            set_tree t key ~retries ?allow_empty ?parents tree ~info
        | `Set, None -> remove t key ~retries ?allow_empty ~info ?parents
        | `Test_and_set, _ -> (
            test_and_set_tree t key ~retries ?allow_empty ?parents ~info
              ~test:old_tree ~set:new_tree
            >>= function
            | Error (`Test_was tr) when retries > 0 && n <= retries ->
                done_once := true;
                aux (n + 1) tr
            | e -> Lwt.return e)
        | `Merge, _ -> (
            merge_tree ~old:old_tree ~retries ?allow_empty ?parents ~info t key
              new_tree
            >>= function
            | Ok _ as x -> Lwt.return x
            | Error (`Conflict _) when retries > 0 && n <= retries ->
                done_once := true;

                (* use the store's current tree as the new 'old store' *)
                let* old_tree =
                  tree_and_head t >>= function
                  | None -> Lwt.return_none
                  | Some (_, tr) -> Tree.find_tree (tr :> tree) key
                in
                aux (n + 1) old_tree
            | Error e -> write_error e)
    in
    let* old_tree = find_tree t key in
    aux 0 old_tree

  let with_tree_exn ?retries ?allow_empty ?parents ?strategy ~info f t key =
    with_tree ?retries ?allow_empty ?strategy ?parents ~info f t key
    >>= fail "with_tree_exn"

  let clone ~src ~dst =
    let* () =
      Head.find src >>= function
      | None -> Branch_store.remove (branch_store src) dst
      | Some h -> Branch_store.set (branch_store src) dst h.h
    in
    of_branch (repo src) dst

  let return_lcas r = function
    | Error _ as e -> Lwt.return e
    | Ok commits ->
        Lwt_list.filter_map_p (Commit.of_hash r) commits >|= Result.ok

  let lcas ?max_depth ?n t1 t2 =
    let* h1 = Head.get t1 in
    let* h2 = Head.get t2 in
    Commits.lcas (commit_store t1) ?max_depth ?n h1.h h2.h
    >>= return_lcas t1.repo

  let lcas_with_commit t ?max_depth ?n c =
    let* h = Head.get t in
    Commits.lcas (commit_store t) ?max_depth ?n h.h c.h >>= return_lcas t.repo

  let lcas_with_branch t ?max_depth ?n b =
    let* h = Head.get t in
    let* head = Head.get { t with head_ref = `Branch b } in
    Commits.lcas (commit_store t) ?max_depth ?n h.h head.h
    >>= return_lcas t.repo

  type 'a merge =
    info:Info.f ->
    ?max_depth:int ->
    ?n:int ->
    'a ->
    (unit, Merge.conflict) result Lwt.t

  let merge_with_branch t ~info ?max_depth ?n other =
    Log.debug (fun f -> f "merge_with_branch %a" pp_branch other);
    Branch_store.find (branch_store t) other >>= function
    | None ->
        Fmt.kstrf Lwt.fail_invalid_arg
          "merge_with_branch: %a is not a valid branch ID" pp_branch other
    | Some c -> (
        Commit.of_hash t.repo c >>= function
        | None -> Lwt.fail_invalid_arg "invalid commit"
        | Some c -> Head.merge ~into:t ~info ?max_depth ?n c)

  let merge_with_commit t ~info ?max_depth ?n other =
    Head.merge ~into:t ~info ?max_depth ?n other

  let merge_into ~into ~info ?max_depth ?n t =
    Log.debug (fun l -> l "merge");
    match head_ref t with
    | `Branch name -> merge_with_branch into ~info ?max_depth ?n name
    | `Head h -> merge_with_commit into ~info ?max_depth ?n h
    | `Empty -> Merge.ok ()

  module History = OCamlGraph.Persistent.Digraph.ConcreteBidirectional (struct
    type t = commit

    let hash h = P.Commit.Key.short_hash h.h
    let compare x y = compare_hash x.h y.h
    let equal x y = equal_hash x.h y.h
  end)

  let filter_graph f g =
    let t = History.empty in
    if Graph.nb_vertex g = 1 then
      match Graph.vertex g with
      | [ v ] -> (
          f v >|= function Some v -> History.add_vertex t v | None -> t)
      | _ -> assert false
    else
      Graph.fold_edges
        (fun x y t ->
          let* t = t in
          let* x = f x in
          let+ y = f y in
          match (x, y) with
          | Some x, Some y ->
              let t = History.add_vertex t x in
              let t = History.add_vertex t y in
              History.add_edge t x y
          | _ -> t)
        g (Lwt.return t)

  let history ?depth ?(min = []) ?(max = []) t =
    Log.debug (fun f -> f "history");
    let pred = function
      | `Commit k ->
          Commits.parents (commit_store t) k
          >>= Lwt_list.filter_map_p (Commit.of_hash t.repo)
          >|= fun parents -> List.map (fun x -> `Commit x.h) parents
      | _ -> Lwt.return_nil
    in
    let* max = Head.find t >|= function Some h -> [ h ] | None -> max in
    let max = List.map (fun k -> `Commit k.h) max in
    let min = List.map (fun k -> `Commit k.h) min in
    let* g = Graph.closure ?depth ~min ~max ~pred () in
    filter_graph
      (function `Commit k -> Commit.of_hash t.repo k | _ -> Lwt.return_none)
      g

  module Heap = Binary_heap.Make (struct
    type t = commit * int

    let compare c1 c2 =
      (* [bheap] operates on miminums, we need to invert the comparison. *)
      -Int64.compare
         (Info.date (Commit.info (fst c1)))
         (Info.date (Commit.info (fst c2)))
  end)

  let last_modified ?depth ?(n = 1) t key =
    Log.debug (fun l ->
        l "last_modified depth=%a n=%d key=%a"
          Fmt.(Dump.option pp_int)
          depth n pp_key key);
    let repo = repo t in
    let* commit = Head.get t in
    let heap = Heap.create ~dummy:(commit, 0) 0 in
    let () = Heap.add heap (commit, 0) in
    let rec search acc =
      if Heap.is_empty heap || List.length acc = n then Lwt.return acc
      else
        let current, current_depth = Heap.pop_minimum heap in
        let parents = Commit.parents current in
        let tree = Commit.tree current in
        let* current_value = Tree.find tree key in
        if List.length parents = 0 then
          if current_value <> None then Lwt.return (current :: acc)
          else Lwt.return acc
        else
          let max_depth =
            match depth with
            | Some depth -> current_depth >= depth
            | None -> false
          in
          let* found =
            Lwt_list.for_all_p
              (fun hash ->
                Commit.of_hash repo hash >>= function
                | Some commit -> (
                    let () =
                      if not max_depth then
                        Heap.add heap (commit, current_depth + 1)
                    in
                    let tree = Commit.tree commit in
                    let+ e = Tree.find tree key in
                    match (e, current_value) with
                    | Some x, Some y -> not (equal_contents x y)
                    | Some _, None -> true
                    | None, Some _ -> true
                    | _, _ -> false)
                | None -> Lwt.return_false)
              parents
          in
          if found then search (current :: acc) else search acc
    in
    search []

  module Branch = struct
    include P.Branch.Key

    let mem t = P.Branch.mem (P.Repo.branch_t t)

    let find t br =
      P.Branch.find (Repo.branch_t t) br >>= function
      | None -> Lwt.return_none
      | Some h -> Commit.of_hash t h

    let set t br h = P.Branch.set (P.Repo.branch_t t) br h.h
    let remove t = P.Branch.remove (P.Repo.branch_t t)
    let list = Repo.branches

    let watch t k ?init f =
      let init = match init with None -> None | Some h -> Some h.h in
      let+ w =
        P.Branch.watch_key (Repo.branch_t t) k ?init (lift_head_diff t f)
      in
      fun () -> Branch_store.unwatch (Repo.branch_t t) w

    let watch_all t ?init f =
      let init =
        match init with
        | None -> None
        | Some i -> Some (List.map (fun (k, v) -> (k, v.h)) i)
      in
      let f k v = lift_head_diff t (f k) v in
      let+ w = P.Branch.watch (Repo.branch_t t) ?init f in
      fun () -> Branch_store.unwatch (Repo.branch_t t) w

    let err_not_found k =
      Fmt.kstrf invalid_arg "Branch.get: %a not found" pp_branch k

    let get t k =
      find t k >>= function None -> err_not_found k | Some v -> Lwt.return v
  end

  module Status = struct
    type t = [ `Empty | `Branch of branch | `Commit of commit ]

    let t r =
      let open Type in
      variant "status" (fun empty branch commit -> function
        | `Empty -> empty | `Branch b -> branch b | `Commit c -> commit c)
      |~ case0 "empty" `Empty
      |~ case1 "branch" Branch.t (fun b -> `Branch b)
      |~ case1 "commit" (Commit.t r) (fun c -> `Commit c)
      |> sealv

    let pp ppf = function
      | `Empty -> Fmt.string ppf "empty"
      | `Branch b -> pp_branch ppf b
      | `Commit c -> pp_hash ppf c.h
  end

  let commit_t = Commit.t
end

module Json_tree (Store : S with type Schema.Contents.t = Contents.json) =
struct
  include Contents.Json_value

  type json = Contents.json

  let to_concrete_tree j : Store.Tree.concrete =
    let rec obj j acc =
      match j with
      | [] -> `Tree acc
      | (k, v) :: l -> (
          match Type.of_string Store.Key.step_t k with
          | Ok key -> obj l ((key, node v []) :: acc)
          | _ -> obj l acc)
    and node j acc =
      match j with
      | `O j -> obj j acc
      | _ -> `Contents (j, Store.Metadata.default)
    in
    node j []

  let of_concrete_tree c : json =
    let step = Type.to_string Store.Key.step_t in
    let rec tree t acc =
      match t with
      | [] -> `O acc
      | (k, v) :: l -> tree l ((step k, contents v []) :: acc)
    and contents t acc =
      match t with `Contents (c, _) -> c | `Tree c -> tree c acc
    in
    contents c []

  let set_tree (tree : Store.tree) key j : Store.tree Lwt.t =
    let c = to_concrete_tree j in
    let c = Store.Tree.of_concrete c in
    Store.Tree.add_tree tree key c

  let get_tree (tree : Store.tree) key =
    let* t = Store.Tree.get_tree tree key in
    let+ c = Store.Tree.to_concrete t in
    of_concrete_tree c

  let set t key j ~info =
    set_tree Store.Tree.empty Store.Key.empty j >>= function
    | tree -> Store.set_tree_exn ~info t key tree

  let get t key =
    let* tree = Store.get_tree t key in
    get_tree tree Store.Key.empty
end

type Remote.t += Store : (module S with type t = 'a) * 'a -> Remote.t

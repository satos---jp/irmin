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
open Cmdliner
open Astring

let global_option_section = "COMMON OPTIONS"

module Conf = Irmin.Private.Conf

let pconv t =
  let pp = Irmin.Type.pp t in
  let parse s =
    match Irmin.Type.of_string t s with
    | Ok x -> `Ok x
    | Error (`Msg e) -> `Error e
  in
  (parse, pp)

let key k default =
  let doc = Conf.doc k in
  let docs = Conf.docs k in
  let docv = Conf.docv k in
  let mk = pconv (Conf.ty k) in
  let name = Conf.name k in
  let i = Arg.info ?docv ?doc ?docs [ name ] in
  Arg.(value & opt mk default i)

let opt_key k = key k (Conf.default k)
let spec' = Conf.Spec.(join (v "unix") [ Irmin_http.Conf.spec ])

let config_path_key =
  Conf.key ~spec:spec' ~docs:global_option_section ~docv:"PATH"
    ~doc:"Allows configuration file to be specified on the command-line."
    "config"
    Irmin.Type.(option string)
    None

let ( / ) = Filename.concat
let global_config_path = "irmin" / "config.yml"

let add_opt k v config =
  match v with None -> config | Some _ -> Conf.add config k v

let add k v config = Conf.add config k v

(* Contents *)

module Contents = struct
  type t = (module Irmin.Contents.S)

  let all =
    ref
      [
        ("string", (module Irmin.Contents.String : Irmin.Contents.S));
        ("json", (module Irmin.Contents.Json));
        ("json-value", (module Irmin.Contents.Json_value));
      ]

  let default = "string" |> fun n -> ref (n, List.assoc n !all)

  let add name ?default:(x = false) m =
    all := (name, m) :: !all;
    if x then default := (name, m)

  let find name =
    match List.assoc_opt (String.Ascii.lowercase name) !all with
    | Some c -> c
    | None ->
        let valid = String.concat ~sep:", " (List.split !all |> fst) in
        let msg =
          Printf.sprintf "Invalid content type: %s. Expected one of: %s." name
            valid
        in
        failwith msg

  let term =
    let content_types = !all |> List.map (fun (name, _) -> (name, name)) in
    let kind =
      let doc =
        Fmt.strf "The type of user-defined contents (%s). Default is `%s'."
          (Arg.doc_alts_enum content_types)
          (fst !default)
      in
      let arg_info =
        Arg.info ~doc ~docs:global_option_section [ "contents"; "c" ]
      in
      Arg.(value & opt (some string) None & arg_info)
    in
    let create kind = kind in
    Term.(const create $ kind)
end

type contents = Contents.t

module Hash = struct
  type t = (module Irmin.Hash.S)
  type hash_function = Fixed of t | Variable_size of (int option -> t)

  module type SIZEABLE = functor
    (S : sig
       val digest_size : int
     end)
    -> Irmin.Hash.S

  let variable_size (module Make : SIZEABLE) (module Default : Irmin.Hash.S) =
    Variable_size
      (function
      | Some s ->
          (module struct
            include Make (struct
              let digest_size = s
            end)
          end : Irmin.Hash.S)
      | None -> (module Default))

  let all =
    ref
      [
        ( "blake2b",
          variable_size
            (module Irmin.Hash.Make_BLAKE2B : SIZEABLE)
            (module Irmin.Hash.BLAKE2B : Irmin.Hash.S) );
        ( "blake2s",
          variable_size
            (module Irmin.Hash.Make_BLAKE2S : SIZEABLE)
            (module Irmin.Hash.BLAKE2S : Irmin.Hash.S) );
        ("rmd160", Fixed (module Irmin.Hash.RMD160 : Irmin.Hash.S));
        ("sha1", Fixed (module Irmin.Hash.SHA1 : Irmin.Hash.S));
        ("sha224", Fixed (module Irmin.Hash.SHA224 : Irmin.Hash.S));
        ("sha256", Fixed (module Irmin.Hash.SHA256 : Irmin.Hash.S));
        ("sha384", Fixed (module Irmin.Hash.SHA384 : Irmin.Hash.S));
        ("sha512", Fixed (module Irmin.Hash.SHA512 : Irmin.Hash.S));
      ]

  let default = ref ("blake2b", (module Irmin.Hash.BLAKE2B : Irmin.Hash.S))

  let add name ?default:(x = false) m =
    all := (name, Fixed m) :: !all;
    if x then default := (name, m)

  let find_hashfn name =
    match List.assoc_opt (String.Ascii.lowercase name) !all with
    | Some c -> c
    | None ->
        let valid = String.concat ~sep:", " (List.split !all |> fst) in
        let msg =
          Printf.sprintf "Invalid hash function: %s. Expected one of: %s." name
            valid
        in
        failwith msg

  let of_specifier hashname =
    let ( >>= ) x f = match x with Ok x -> f x | Error _ as e -> e in
    (match String.cut ~rev:true ~sep:"/" hashname with
    | Some (hashname, size) -> (
        match int_of_string_opt size with
        | Some size -> Ok (hashname, Some size)
        | None -> Error (`Msg (Fmt.strf "Non-numeric hash size %s passed" size))
        )
    | None -> Ok (hashname, None))
    >>= fun (hashname, size_opt) ->
    match (find_hashfn hashname, size_opt) with
    | Variable_size hashfn, size_opt -> Ok (hashfn size_opt)
    | Fixed hashfn, None -> Ok hashfn
    | Fixed _, Some size ->
        Error
          (`Msg
            (Fmt.strf
               "Cannot specify a size for hash function `%s' (%d passed)."
               hashname size))

  let find h =
    of_specifier h |> function Ok h -> h | Error (`Msg e) -> failwith e

  let hash_function_conv : t Cmdliner.Arg.conv = Arg.conv (of_specifier, Fmt.nop)

  let term =
    let kind =
      let quote s = Fmt.strf "`%s'" s in
      let hash_types = !all |> List.map (fun (name, _) -> (name, name)) in
      let variable_size_types =
        !all
        |> List.filter (function
             | _, Variable_size _ -> true
             | _, Fixed _ -> false)
        |> List.map fst
      in
      let pp_prose_list =
        Fmt.of_to_string (function
          | [] -> ""
          | [ h ] -> quote h
          | hs ->
              let rev_hs = List.rev hs in
              Fmt.strf "%s and %s"
                (String.concat ~sep:", " (List.rev_map quote (List.tl rev_hs)))
                (quote (List.hd rev_hs)))
      in
      let pp_plural =
        Fmt.of_to_string (function _ :: _ :: _ -> "s" | _ -> "")
      in
      let pp_variable_size_doc ppf = function
        | [] -> ()
        | _ :: _ as hs ->
            Fmt.pf ppf
              "\n\
               The bit-length of the hash function%a %a may optionally be set \
               with a trailing slash (e.g. `%s/16')."
              pp_plural hs pp_prose_list hs (List.hd hs)
      in
      let doc =
        Fmt.strf "The hash function (%s). Default is `%s'.%a"
          (Arg.doc_alts_enum hash_types)
          (fst !default) pp_variable_size_doc variable_size_types
      in
      let arg_info =
        Arg.info ~doc ~docs:global_option_section [ "hash"; "h" ]
      in
      Arg.(value & opt (some hash_function_conv) None & arg_info)
    in
    let create kind = kind in
    Term.(const create $ kind)
end

type hash = Hash.t

(* Store *)

module Store = struct
  type remote_fn =
    ?ctx:Mimic.ctx -> ?headers:Cohttp.Header.t -> string -> Irmin.remote

  type t =
    | T : (module Irmin.S) * Irmin.Private.Conf.Spec.t * remote_fn option -> t

  let destruct (T (a, b, c)) = (a, b, c)

  type store_functor =
    | Fixed_hash of (contents -> t)
    | Variable_hash of (hash -> contents -> t)

  module type G = sig
    include Irmin.S

    val remote : remote_fn
  end

  let v ?remote spec s = T (s, spec, remote)
  let v_git (module S : G) = v Irmin_git.Conf.spec (module S) ~remote:S.remote

  let create :
      Irmin.Private.Conf.Spec.t -> (module Irmin.Maker) -> hash -> contents -> t
      =
   fun spec (module S) (module H) (module C) ->
    let module S = S.Make (Irmin.Schema.KV (C)) in
    T ((module S), spec, None)

  let mem = create Irmin_mem.Conf.spec (module Irmin_mem)
  let irf = create Irmin_fs.Conf.spec (module Fs)

  let http = function
    | T ((module S), spec, x) ->
        T
          ( (module Http.Client (S)),
            Irmin.Private.Conf.Spec.join spec [ Irmin_http.Conf.spec ],
            x )

  let git (module C : Irmin.Contents.S) = v_git (module Xgit.FS.KV (C))
  let git_mem (module C : Irmin.Contents.S) = v_git (module Xgit.Mem.KV (C))

  module Inode_config = struct
    let entries = 32
    let stable_hash = 256
  end

  let pack = create Irmin_pack.Conf.spec (module Irmin_pack.V1 (Inode_config))

  let all =
    ref
      [
        ("git", Fixed_hash git);
        ("git-mem", Fixed_hash git_mem);
        ("irf", Variable_hash irf);
        ("mem", Variable_hash mem);
        ("mem-http", Variable_hash (fun h c -> http (mem h c)));
        ("git-http", Fixed_hash (fun c -> http (git c)));
        ("pack", Variable_hash pack);
        ("pack-http", Variable_hash (fun h c -> http (pack h c)));
      ]

  let default = "git" |> fun n -> ref (n, List.assoc n !all)

  let add name ?default:(x = false) m =
    all := (name, m) :: !all;
    if x then default := (name, m)

  let find name =
    match List.assoc_opt (String.Ascii.lowercase name) !all with
    | Some s -> s
    | None ->
        let valid = String.concat ~sep:", " (List.split !all |> fst) in
        let msg =
          Printf.sprintf "Invalid store type: %s. Expected one of: %s." name
            valid
        in
        failwith msg

  let term =
    let store =
      let store_types = !all |> List.map (fun (name, _) -> (name, name)) in
      let doc =
        Fmt.strf "The storage backend (%s). Default is `%s'."
          (Arg.doc_alts_enum store_types)
          (fst !default)
      in
      let arg_info =
        Arg.info ~doc ~docs:global_option_section [ "s"; "store" ]
      in
      Arg.(value & opt (some (enum store_types)) None & arg_info)
    in
    let create store hash contents = (store, hash, contents) in
    Term.(const create $ store $ Hash.term $ Contents.term)
end

(* Config *)

let home =
  try Sys.getenv "HOME"
  with Not_found -> (
    try (Unix.getpwuid (Unix.getuid ())).Unix.pw_dir
    with Unix.Unix_error _ | Not_found ->
      if Sys.win32 then try Sys.getenv "AppData" with Not_found -> "" else "")

let config_root () =
  try Sys.getenv "XDG_CONFIG_HOME"
  with Not_found ->
    if Sys.win32 then home / "Local Settings" else home / ".config"

let rec read_config_file path =
  let home = config_root () / global_config_path in
  let path =
    match path with
    | Some path ->
        if (not (Sys.file_exists path)) && not (String.equal path home) then
          Fmt.failwith "config file does not exist: %s" path
        else path
    | None -> "irmin.yml"
  in
  let global =
    if String.equal path home then [] else read_config_file (Some home)
  in
  if not (Sys.file_exists path) then global
  else
    let () = Logs.debug (fun f -> f "Loading config from file: %s" path) in
    let oc = open_in path in
    let len = in_channel_length oc in
    let buf = really_input_string oc len in
    close_in oc;
    match Yaml.of_string buf with
    | Ok (`O y) -> y @ global
    | Ok _ -> Fmt.failwith "invalid YAML file: %s" path
    | Error (`Msg msg) -> Fmt.failwith "unable to parse YAML: %s" msg

let root_key = Conf.root spec'

let config_term =
  let create root config_path (opts : (string * string) list list) =
    let config =
      Conf.empty spec' |> add root_key root |> add config_path_key config_path
    in
    (config, opts)
  in
  let doc =
    Seq.map (fun (Irmin.Private.Conf.K x) -> Conf.name x) (Conf.Spec.keys spec')
    |> List.of_seq
    |> String.concat ~sep:", "
  in
  let doc = "Backend-specific options: " ^ doc in
  let opts =
    Arg.info ~docv:"OPTIONS" ~docs:global_option_section ~doc
      [ "opt"; "options" ]
  in
  Term.(
    const create
    $ opt_key root_key
    $ opt_key config_path_key
    $ Arg.(value @@ opt_all (list (pair ~sep:'=' string string)) [] opts))

type store =
  | S :
      (module Irmin.S with type t = 'a) * 'a Lwt.t * Store.remote_fn option
      -> store

let string_value = function `String s -> s | _ -> raise Not_found

let assoc y name fn =
  try Some (fn (List.assoc name y |> string_value)) with Not_found -> None

let rec json_of_yaml : Yaml.value -> Yojson.Basic.t = function
  | `O x -> `Assoc (List.map (fun (k, v) -> (k, json_of_yaml v)) x)
  | `A x -> `List (List.map json_of_yaml x)
  | (`Null | `Bool _ | `Float _ | `String _) as x -> x

let load_config_file_with_defaults path (store, hash, contents) config =
  let y = read_config_file path in
  let store =
    match List.assoc_opt "store" y with
    | Some (`String s) -> Store.find s
    | _ -> (
        match store with Some s -> Store.find s | None -> snd !Store.default)
  in
  let contents =
    match List.assoc_opt "contents" y with
    | Some (`String s) -> Contents.find s
    | _ -> (
        match contents with
        | Some s -> Contents.find s
        | None -> snd !Contents.default)
  in
  let hash =
    match List.assoc_opt "hash" y with
    | Some (`String s) -> Some (Hash.find s)
    | _ -> ( match hash with Some s -> Some s | None -> None)
  in
  let store =
    match store with
    | Store.Variable_hash s ->
        let hash : hash = Option.value ~default:(snd !Hash.default) hash in
        s hash contents
    | Fixed_hash s -> (
        (* error if a hash function has been passed *)
        match hash with
        | None -> s contents
        | _ ->
            Fmt.failwith
              "Cannot customize the hash function for the given store")
  in
  let _, spec, _ = Store.destruct store in
  let config =
    List.fold_left
      (fun config (k, v) ->
        match Conf.Spec.find_key spec k with
        | Some (Irmin.Private.Conf.K k) ->
            let v = json_of_yaml v |> Yojson.Basic.to_string in
            let v =
              match Irmin.Type.of_json_string (Conf.ty k) v with
              | Error _ ->
                  let v = Format.sprintf "{\"some\": %s}" v in
                  Irmin.Type.of_json_string (Conf.ty k) v |> Result.get_ok
              | Ok v -> v
            in
            Conf.add config k v
        | None -> (
            match k with
            | "contents" | "hash" | "store" -> config
            | _ ->
                Fmt.invalid_arg "unknown config key for %s: %s"
                  (Conf.Spec.name spec) k))
      (Conf.with_spec config spec)
      y
  in
  (store, config)

let from_config_file_with_defaults path (store, hash, contents) config opts
    branch : store =
  let y = read_config_file path in
  let store, config =
    load_config_file_with_defaults path (store, hash, contents) config
  in
  match store with
  | Store.T ((module S), spec, remote) -> (
      let config =
        List.fold_left
          (fun config (k, v) ->
            let (Irmin.Private.Conf.K key) =
              if k = "root" then
                invalid_arg
                  "use the --root flag to set the root directory instead of \
                   passing it as a config"
              else
                match Conf.Spec.find_key spec k with
                | Some x -> x
                | None -> invalid_arg ("opt: " ^ k)
            in
            let ty = Conf.ty key in
            let v =
              match Irmin.Type.of_string ty v with
              | Error _ -> (
                  let x = Format.sprintf "{\"some\": %s}" v in
                  match Irmin.Type.of_string (Conf.ty key) x with
                  | Error _ ->
                      let y = Format.sprintf "{\"some\": \"%s\"}" v in
                      Irmin.Type.of_string (Conf.ty key) y |> Result.get_ok
                  | Ok v -> v)
              | Ok v -> v
            in
            let config = Conf.add config key v in
            config)
          config (List.flatten opts)
      in
      let mk_master () = S.Repo.v config >>= fun repo -> S.master repo in
      let mk_branch b = S.Repo.v config >>= fun repo -> S.of_branch repo b in
      let branch =
        let of_string = Irmin.Type.of_string S.Branch.t in
        match branch with
        | None ->
            assoc y "branch" (fun x ->
                match of_string x with
                | Ok x -> x
                | Error (`Msg msg) -> failwith msg)
        | Some t -> (
            match of_string t with
            | Ok x -> Some x
            | Error (`Msg e) -> failwith e)
      in
      match branch with
      | None -> S ((module S), mk_master (), remote)
      | Some b -> S ((module S), mk_branch b, remote))

let load_config ?(default = Conf.empty spec') ?config_path ?store ?hash
    ?contents () =
  let cfg =
    match config_path with
    | Some _ as p -> p
    | None -> Conf.get default config_path_key
  in
  load_config_file_with_defaults cfg (store, hash, contents) default

let branch =
  let doc =
    Arg.info
      ~doc:"The current branch name. Default is the store's master branch."
      ~docs:global_option_section ~docv:"BRANCH" [ "b"; "branch" ]
  in
  Arg.(value & opt (some string) None & doc)

let store =
  let create store (config, opts) branch =
    let cfg = Conf.get config config_path_key in
    from_config_file_with_defaults cfg store config opts branch
  in
  Term.(const create $ Store.term $ config_term $ branch)

let header_conv =
  let parse str =
    match String.cut ~sep:":" str with
    | Some (k, v) -> Ok (String.trim k, String.trim v)
    | None -> Error (`Msg "invalid header")
  in
  let print ppf (k, v) = Fmt.pf ppf "%s: %s" k v in
  Cmdliner.Arg.conv (parse, print)

let headers =
  let doc =
    Arg.info ~docv:"HEADER" ~doc:"Extra HTTP headers to use when sync." [ "H" ]
  in
  Arg.(value & opt_all header_conv [] & doc)

type Irmin.remote += R of Cohttp.Header.t option * string

(* FIXME: this is a very crude heuristic to choose the remote
   kind. Would be better to read the config file and look for remote
   alias. *)
let infer_remote hash contents headers str =
  let hash = match hash with None -> snd !Hash.default | Some c -> c in
  let contents =
    match contents with
    | None -> snd !Contents.default
    | Some c -> Contents.find c
  in
  if Sys.file_exists str then
    let r =
      if Sys.file_exists (str / ".git") then Store.git contents
      else Store.irf hash contents
    in
    match r with
    | Store.T ((module R), spec, _) ->
        let config =
          Conf.empty spec
          |> add_opt Irmin_http.Conf.Key.uri (Some (Uri.of_string str))
          |> add root_key str
        in
        let* repo = R.Repo.v config in
        let+ r = R.master repo in
        Irmin.remote_store (module R) r
  else
    let headers =
      match headers with [] -> None | h -> Some (Cohttp.Header.of_list h)
    in
    Lwt.return (R (headers, str))

let remote =
  let repo =
    let doc =
      Arg.info ~docv:"REMOTE"
        ~doc:"The URI of the remote repository to clone from." []
    in
    Arg.(required & pos 0 (some string) None & doc)
  in
  Term.(const infer_remote $ Hash.term $ Contents.term $ headers $ repo)

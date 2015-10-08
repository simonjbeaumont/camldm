(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

let ignore_string (_: string) = ()

let log fmt =
  Printf.ksprintf
    (fun s ->
      output_string stderr s;
      output_string stderr "\n";
      flush stderr;
      ) fmt
let debug fmt = log fmt
let warn fmt = debug fmt
let error fmt = debug fmt

let finally f g =
  try
    let result = f () in
    g ();
    result
  with e ->
    g ();
    raise e

let string_of_file filename =
  let ic = open_in filename in
  let output = Buffer.create 1024 in
  try
    while true do
      let block = String.make 4096 '\000' in
      let n = input ic block 0 (String.length block) in
      if n = 0 then raise End_of_file;
      Buffer.add_substring output block 0 n
    done;
    "" (* never happens *)
  with End_of_file ->
    close_in ic;
    Buffer.contents output

let file_of_string filename string =
  let oc = open_out filename in
  finally
    (fun () ->
      debug "write >%s" filename;
      output oc string 0 (String.length string)
    ) (fun () -> close_out oc)

let startswith prefix x =
  let prefix' = String.length prefix in
  let x' = String.length x in
  x' >= prefix' && (String.sub x 0 prefix' = prefix)

let remove_prefix prefix x =
  let prefix' = String.length prefix in
  let x' = String.length x in
  String.sub x prefix' (x' - prefix')

let endswith suffix x =
  let suffix' = String.length suffix in
  let x' = String.length x in
  x' >= suffix' && (String.sub x (x' - suffix') suffix' = suffix)

let iso8601_of_float x =
  let time = Unix.gmtime x in
  Printf.sprintf "%04d%02d%02dT%02d:%02d:%02dZ"
    (time.Unix.tm_year+1900)
    (time.Unix.tm_mon+1)
    time.Unix.tm_mday
    time.Unix.tm_hour
    time.Unix.tm_min
    time.Unix.tm_sec


(** create a directory, and create parent if doesn't exist *)
let mkdir_rec dir perm =
  let mkdir_safe dir perm =
    try Unix.mkdir dir perm with Unix.Unix_error (Unix.EEXIST, _, _) -> () in
  let rec p_mkdir dir =
    let p_name = Filename.dirname dir in
    if p_name <> "/" && p_name <> "."
    then p_mkdir p_name;
    mkdir_safe dir perm in
  p_mkdir dir

let rm_f x =
  try
    Unix.unlink x;
    debug "rm %s" x
   with _ ->
    debug "%s already deleted" x;
    ()

let ( |> ) a b = b a

(* From Xcp_service: *)
let colon = Re_str.regexp_string ":"

let canonicalise x =
  if not(Filename.is_implicit x)
  then x
  else begin
    (* Search the PATH and XCP_PATH for the executable *)
    let paths = Re_str.split colon (Sys.getenv "PATH") in
    let xen_paths = try Re_str.split colon (Sys.getenv "XCP_PATH") with _ -> [] in
    let first_hit = List.fold_left (fun found path -> match found with
      | Some hit -> found
      | None ->
        let possibility = Filename.concat path x in
        if Sys.file_exists possibility
        then Some possibility
        else None
    ) None (paths @ xen_paths) in
    match first_hit with
    | None ->
      warn "Failed to find %s on $PATH ( = %s) or $XCP_PATH ( = %s)" x (Sys.getenv "PATH") (try Sys.getenv "XCP_PATH" with Not_found -> "unset");
      x
    | Some hit -> hit
  end

exception Bad_exit of int * string * string list * string * string

let run ?(env= [| |]) ?stdin cmd args =
  let cmd = canonicalise cmd in
  debug "%s %s" cmd (String.concat " " args);
  let null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  let to_close = ref [ null ] in
  let close fd =
    if List.mem fd !to_close then begin
      to_close := List.filter (fun x -> x <> fd) !to_close;
      Unix.close fd
    end in
  let read_all fd =
    let b = Buffer.create 128 in
    let tmp = String.make 4096 '\000' in
    let finished = ref false in
    while not !finished do
      let n = Unix.read fd tmp 0 (String.length tmp) in
      Buffer.add_substring b tmp 0 n;
      finished := n = 0
    done;
    Buffer.contents b in
  let close_all () = List.iter close !to_close in
  try
    (* stdin is a pipe *)
    let stdin_readable, stdin_writable = Unix.pipe () in
    to_close := stdin_readable :: stdin_writable :: !to_close;
    (* stdout buffers to a temp file *)
    let stdout_filename = Filename.temp_file (Filename.basename Sys.argv.(0)) "stdout" in
    let stdout_readable = Unix.openfile stdout_filename [ Unix.O_RDONLY; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o0600 in
    let stdout_writable = Unix.openfile stdout_filename [ Unix.O_WRONLY ] 0o0600 in
    to_close := stdout_readable :: stdout_writable :: !to_close;
    Unix.unlink stdout_filename;
    (* stderr buffers to a temp file *)
    let stderr_filename = Filename.temp_file (Filename.basename Sys.argv.(0)) "stderr" in
    let stderr_readable = Unix.openfile stderr_filename [ Unix.O_RDONLY; Unix.O_CREAT; Unix.O_CLOEXEC ] 0o0600 in
    let stderr_writable = Unix.openfile stderr_filename [ Unix.O_WRONLY ] 0o0600 in
    to_close := stderr_readable :: stderr_writable :: !to_close;
    Unix.unlink stderr_filename;

    let pid = Unix.create_process_env cmd (Array.of_list (cmd :: args)) env stdin_readable stdout_writable stderr_writable in
    close stdin_readable;
    close stdout_writable;
    close stderr_writable;

    (* pump the input to stdin while the output is streaming to the unlinked files *)
    begin match stdin with
    | None -> ()
    | Some txt ->
      let n = Unix.write stdin_writable txt 0 (String.length txt) in
      if n <> (String.length txt)
      then failwith (Printf.sprintf "short write to process stdin: only wrote %d bytes" n);
    end;
    close stdin_writable;

    let _, status = Unix.waitpid [] pid in

    let stdout = read_all stdout_readable in
    let stderr = read_all stderr_readable in    
    close_all ();

    match status with
    | Unix.WEXITED 0 ->
      stdout
    | Unix.WEXITED n ->
      raise (Bad_exit(n, cmd, args, stdout, stderr))
    | _ ->
      failwith (Printf.sprintf "%s %s failed" cmd (String.concat " " args))
  with e ->
    close_all ();
    raise e

module Int64 = struct
  include Int64

  let ( + ) = Int64.add
  let ( - ) = Int64.sub
  let ( * ) = Int64.mul
  let ( / ) = Int64.div
end

let kib = 1024L
let mib = Int64.(kib * kib)
let gib = Int64.(mib * kib)
let tib = Int64.(gib * kib)

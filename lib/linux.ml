(*
 * Copyright (C) 2014 Citrix Systems Inc.
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
open Sexplib.Std

module Lowlevel = struct
  (** The unsafe direct interface to the C library *)

  open Ctypes
  open PosixTypes
  open Foreign

  let from = Dl.dlopen ~filename:"libdevmapper.so" ~flags:[Dl.RTLD_LAZY]

  type kind =
  | DM_DEVICE_CREATE
  | DM_DEVICE_RELOAD
  | DM_DEVICE_REMOVE
  | DM_DEVICE_REMOVE_ALL
  | DM_DEVICE_SUSPEND
  | DM_DEVICE_RESUME
  | DM_DEVICE_INFO
  | DM_DEVICE_DEPS
  | DM_DEVICE_RENAME
  | DM_DEVICE_VERSION
  | DM_DEVICE_STATUS
  | DM_DEVICE_TABLE
  | DM_DEVICE_WAITEVENT
  | DM_DEVICE_LIST
  | DM_DEVICE_CLEAR
  | DM_DEVICE_MKNODES
  | DM_DEVICE_LIST_VERSIONS
  | DM_DEVICE_TARGET_MSG
  | DM_DEVICE_SET_GEOMETRY
  (* These must match libdevmapper.h: *)
  let dm_kind_to_int = function
  | DM_DEVICE_CREATE        -> 0
  | DM_DEVICE_RELOAD        -> 1
  | DM_DEVICE_REMOVE        -> 2
  | DM_DEVICE_REMOVE_ALL    -> 3
  | DM_DEVICE_SUSPEND       -> 4
  | DM_DEVICE_RESUME        -> 5
  | DM_DEVICE_INFO          -> 6
  | DM_DEVICE_DEPS          -> 7
  | DM_DEVICE_RENAME        -> 8
  | DM_DEVICE_VERSION       -> 9
  | DM_DEVICE_STATUS        -> 10
  | DM_DEVICE_TABLE         -> 11
  | DM_DEVICE_WAITEVENT     -> 12
  | DM_DEVICE_LIST          -> 13
  | DM_DEVICE_CLEAR         -> 14
  | DM_DEVICE_MKNODES       -> 15
  | DM_DEVICE_LIST_VERSIONS -> 16
  | DM_DEVICE_TARGET_MSG    -> 17
  | DM_DEVICE_SET_GEOMETRY  -> 18

  type dm_task = [ `Dm_task ] structure ptr

  let dm_task : dm_task typ = ptr (structure "dm_task")
  let dm_task_opt : dm_task option typ = ptr_opt (structure "dm_task")

  let dm_task_create' = foreign ~from "dm_task_create" (int @-> returning dm_task_opt)
  let dm_task_create kind = dm_task_create' (dm_kind_to_int kind)

  let dm_task_destroy = foreign ~from "dm_task_destroy" (dm_task @-> returning void)

  let bool = view ~read:((<>)0) ~write:(fun b -> compare b false) int

  let dm_task_set_name = foreign ~from "dm_task_set_name" (dm_task @-> string @-> returning bool)
  let dm_task_set_uuid = foreign ~from "dm_task_set_uuid" (dm_task @-> string @-> returning bool)

  let dm_task_run = foreign ~from "dm_task_run" (dm_task @-> returning bool)
  
  let dm_task_add_target = foreign ~from "dm_task_add_target" (dm_task @-> uint64_t @-> uint64_t @-> string @-> string @-> returning bool)

  let dm_mknodes = foreign ~from "dm_mknodes" (string_opt @-> returning bool)

  type dm_info = [ `Dm_info ] structure ptr

  let struct_dm_info = structure "dm_info"
  let struct_dm_info_exists = field struct_dm_info "exists" int
  let struct_dm_info_suspended = field struct_dm_info "suspended" int
  let struct_dm_info_live_table = field struct_dm_info "live_table" int
  let struct_dm_info_inactive_table = field struct_dm_info "inactive_table" int
  let struct_dm_info_open_count = field struct_dm_info "open_count" int32_t
  let struct_dm_info_event_nr = field struct_dm_info "event_nr" uint32_t
  let struct_dm_info_major = field struct_dm_info "major" uint32_t
  let struct_dm_info_minor = field struct_dm_info "minor" uint32_t
  let struct_dm_info_read_only = field struct_dm_info "read_only" int (* 0:read-write 1:read-only *)
  let struct_dm_info_target_count = field struct_dm_info "target_count" int32_t
  let struct_dm_info_deferred_remove = field struct_dm_info "deferred_remove" int
  let () = seal struct_dm_info

  let dm_info : dm_info typ = ptr struct_dm_info
  let dm_info_opt : dm_info option typ = ptr_opt struct_dm_info

  let dm_task_get_info = foreign ~from "dm_task_get_info" (dm_task @-> dm_info @-> returning bool)

  let dm_get_next_target = foreign ~from "dm_get_next_target" (dm_task @-> (ptr void) @-> (ptr uint64_t) @-> (ptr uint64_t) @-> (ptr string_opt) @-> (ptr string_opt) @-> returning (ptr void))

  let struct_dm_names = structure "dm_names"
  let struct_dm_names_dev = field struct_dm_names "dev" uint64_t
  let struct_dm_names_next = field struct_dm_names "next" uint32_t
  let struct_dm_names_name = field struct_dm_names "name" char
  let () = seal struct_dm_names
  type dm_names = [ `Dm_names ] structure ptr
  let dm_names : dm_names typ = ptr struct_dm_names
  let dm_names_opt : dm_names option typ = ptr_opt struct_dm_names

  let dm_task_get_names = foreign ~from "dm_task_get_names" (dm_task @-> returning dm_names_opt)

  let dm_task_set_cookie = foreign ~from "dm_task_set_cookie" (dm_task @-> (ptr uint32_t) @-> uint16_t @-> returning bool)

  let dm_udev_wait = foreign ~from "dm_udev_wait" (uint32_t @-> returning bool)

  external mknod : string -> int -> int -> int -> unit = "camldm_mknod"
end

let finally f g =
  try
    let result = f () in
    g ();
    result
  with e ->
    g ();
    raise e

let with_task kind f =
  let open Lowlevel in
  match dm_task_create kind with
  | None -> failwith "Failed to create device-mapper task; check permissions and retry"
  | Some dm_task ->
    finally
      (fun () -> f dm_task)
      (fun () -> dm_task_destroy dm_task)

let _simple kind name =
  let open Lowlevel in
  with_task kind
    (fun dm_task ->
      if not (dm_task_set_name dm_task name)
      then failwith (Printf.sprintf "dm_task_set_name %s failed" name);
      if not (dm_task_run dm_task)
      then failwith "dm_task_run failed"
    )

let remove = _simple Lowlevel.DM_DEVICE_REMOVE    
let suspend = _simple Lowlevel.DM_DEVICE_SUSPEND
let resume = _simple Lowlevel.DM_DEVICE_RESUME

let create_reload_common kind name targets =
  let open Ctypes in
  let open PosixTypes in
  let open Lowlevel in
  with_task kind
    (fun dm_task ->
      if not (dm_task_set_name dm_task name)
      then failwith (Printf.sprintf "dm_task_set_name %s failed" name);
      List.iter
        (fun t ->
          let open Unsigned.UInt64 in
          let open Target in
          let ttype, params = marshal t.kind in
          if not (dm_task_add_target dm_task (of_int64 t.start) (of_int64 t.size) ttype params)
          then failwith (Printf.sprintf "dm_task_add_target %s failed" (Sexplib.Sexp.to_string (sexp_of_t t)));
        ) targets;

      if not (dm_task_run dm_task)
      then failwith "dm_task_run failed";
    )

let create = create_reload_common Lowlevel.DM_DEVICE_CREATE
let reload = create_reload_common Lowlevel.DM_DEVICE_RELOAD

type info = {
  suspended: bool;
  live_table: int;
  inactive_table: int;
  open_count: int32;
  event_nr: int32;
  major: int32;
  minor: int32;
  read_only: bool;
  target_count: int32;
  deferred_remove: int;
  targets: Target.t list;
} with sexp

let stat name =
  let open Ctypes in
  let open PosixTypes in
  let open Lowlevel in
  let dm_info = make struct_dm_info in
  let rec read_targets dm_task next =
    let start = allocate uint64_t (Unsigned.UInt64.of_int64 0L) in
    let size = allocate uint64_t (Unsigned.UInt64.of_int64 0L) in
    let ttype = allocate string_opt None in
    let params = allocate string_opt None in
    let next = dm_get_next_target dm_task next start size ttype params in
    let start = Unsigned.UInt64.to_int64 (!@ start) in
    let size = Unsigned.UInt64.to_int64 (!@ size) in
    let open Target in
    match !@ ttype, !@ params with
    | Some t, Some p ->
      let kind = unmarshal (t, p) in
      let target = { start; size; kind } in
      if next = null
      then [ target ]
      else target :: (read_targets dm_task next)
    | _ -> [] in
  let read_info targets =
    let suspended = getf dm_info struct_dm_info_suspended <> 0 in
    let live_table = getf dm_info struct_dm_info_live_table in
    let inactive_table = getf dm_info struct_dm_info_inactive_table in
    let open_count = getf dm_info struct_dm_info_open_count in
    let event_nr = getf dm_info struct_dm_info_event_nr |> Unsigned.UInt32.to_int32 in
    let major = getf dm_info struct_dm_info_major |> Unsigned.UInt32.to_int32 in
    let minor = getf dm_info struct_dm_info_minor |> Unsigned.UInt32.to_int32 in
    let read_only = getf dm_info struct_dm_info_read_only <> 0 in
    let target_count = getf dm_info struct_dm_info_target_count in
    let deferred_remove = getf dm_info struct_dm_info_deferred_remove in
    { suspended; live_table; inactive_table; open_count; event_nr;
      major; minor; read_only; target_count; deferred_remove; targets } in
  try
    with_task DM_DEVICE_TABLE
      (fun dm_task ->
        if not (dm_task_set_name dm_task name)
        then failwith (Printf.sprintf "dm_task_set_name %s failed" name);
        if not (dm_task_run dm_task)
        then failwith "dm_task_run failed";
        if not (dm_task_get_info dm_task (addr dm_info))
        then failwith "dm_task_get_info failed";
        if getf dm_info struct_dm_info_exists = 0
        then None
        else Some (read_info (read_targets dm_task null))
      )
  with _ -> None

let mknod name path mode =
  match stat name with
  | Some info ->
    Lowlevel.mknod path mode (Int32.to_int info.major) (Int32.to_int info.minor)
  | None ->
    failwith (Printf.sprintf "Device mapper device %s not found" name)

let ls () =
  let open Lowlevel in
  let open Ctypes in
  let open PosixTypes in

  let string_of_char_ptr p =
    let b = Buffer.create 16 in
    let rec loop p =
      let c = !@ p in
      if c = '\000'
      then Buffer.contents b
      else begin
        Buffer.add_char b c;
        loop (p +@ 1)
      end in
    loop p in

  with_task DM_DEVICE_LIST
    (fun dm_task ->
      if not (dm_task_run dm_task)
      then failwith "dm_task_run failed";
      match dm_task_get_names dm_task with
      | None -> failwith "dm_task_get_names failed"
      | Some dm_names ->
        let s = !@ dm_names in
        if Unsigned.UInt64.to_int64 (getf s struct_dm_names_dev) = 0L
        then []
        else begin
          let ptr = to_voidp dm_names in
          let rec loop ptr next =
            let ptr = ptr_of_raw_address (Nativeint.(add (raw_address_of_ptr ptr) (of_int next))) in
            let s = !@ (from_voidp struct_dm_names ptr) in
            let name = string_of_char_ptr (s @. struct_dm_names_name) in
            let next = Unsigned.UInt32.to_int (getf s struct_dm_names_next) in
            if next = 0
            then [ name ]
            else name :: (loop ptr next) in
          loop ptr 0
        end
    )

type device = string

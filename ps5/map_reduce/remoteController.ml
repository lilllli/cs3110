open Async.Std

let addresses = ref []

let init addrs : unit =
  addresses := List.map (fun (s,i) ->
    Tcp.to_host_and_port s i) addrs;

exception InfrastructureFailure
exception MapFailure of string
exception ReduceFailure of string

(* Remember that map_reduce should be parallelized. Note that [Deferred.List]
 * functions are run sequentially by default. To achieve parallelism, you may
 * find the data structures and functions you implemented in the warmup
 * useful. Or, you can pass [~how:`Parallel] as an argument to the
 * [Deferred.List] functions.*)
module Make (Job : MapReduce.Job) = struct
  module Request = Protocol.WorkerRequest(Job)
  module Response = Protocol.WorkerResponse(Job)

  let map_reduce inputs =
    let active = ref 0 in
    let queue = AQueue.create () in 

    let connect () =
      Deferred.List.map (!addresses) (fun addr ->
        (try_with (fun () -> Tcp.connect addr))
        >>= (function
          | Core.Std.Error _ -> return ()
          | Core.Std.Ok (s,r,w) ->
            (try_with (fun () -> return Writer.write_line w Job.name))
              >>| (function
                | Core.Std.Error _ -> failwith "Writer's block"
                | Core.Std.Ok _ -> (s,r,w))
            >>| (fun a ->
              ignore (active := (!active) + 1);
              ignore (AQueue.push queue a);
              ()))
      ) in

    let rec execute input =
      if ((!active) = 0) then
        raise (InfrastructureFailure "All workers inactive!")
      else
        (AQueue.pop queue) >>= (fun (s,r,w) ->
          ignore (Request.send w (Request.MapRequest (input)));
          Response.receive r >>= fun resp ->
            ignore (AQueue.push queue (s,r,w));
            match resp with
              | `Eof ->
                ignore (Socket.shutdown socket `Both);
                ignore (active := (!active) - 1);
                execute input
              | `Ok result -> (match result with
                | Response.JobFailed e -> raise (MapFailed e)
                | Response.ReduceResult a ->
                  Socket.shutdown socket `Both;
                  active := (!active) - 1;
                  assign_work input  
                | Response.MapResult a -> return a)
        )



end







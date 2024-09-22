import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/function
import gleam/io
import gleam/json.{type Json}
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gleam/set
import gleam/string

import fiber
import fiber/message

pub fn selector(
  send_back: process.Subject(process.Subject(fiber.RpcMessage)),
) -> process.Selector(fiber.RpcMessage) {
  let subject = process.new_subject()

  process.send(send_back, subject)

  process.new_selector()
  |> process.selecting(subject, function.identity)
}

fn stop_on_error(result: Result(a, b), state: d) -> actor.Next(c, d) {
  case result {
    Error(_) -> actor.Stop(process.Abnormal("Socket Closed"))
    Ok(_) -> actor.continue(state)
  }
}

fn add_waiting(
  connection: fiber.RpcConnection(a, b),
  id: message.Id,
  reply: process.Subject(Result(Dynamic, message.ErrorData(Dynamic))),
) -> fiber.RpcConnection(a, b) {
  fiber.RpcConnection(
    ..connection,
    waiting: connection.waiting |> dict.insert(id, reply),
  )
}

fn add_waiting_batch(
  connection: fiber.RpcConnection(a, b),
  ids: set.Set(message.Id),
  reply: process.Subject(
    Dict(message.Id, Result(Dynamic, message.ErrorData(Dynamic))),
  ),
) -> fiber.RpcConnection(a, b) {
  fiber.RpcConnection(
    ..connection,
    waiting_batches: connection.waiting_batches |> dict.insert(ids, reply),
  )
}

fn remove_waiting(
  connection: fiber.RpcConnection(a, b),
  id: message.Id,
) -> fiber.RpcConnection(a, b) {
  fiber.RpcConnection(
    ..connection,
    waiting: connection.waiting |> dict.delete(id),
  )
}

fn remove_waiting_batch(
  connection: fiber.RpcConnection(a, b),
  ids: set.Set(message.Id),
) -> fiber.RpcConnection(a, b) {
  fiber.RpcConnection(
    ..connection,
    waiting_batches: connection.waiting_batches |> dict.delete(ids),
  )
}

pub fn handle_text(
  rpc: fiber.RpcConnection(a, b),
  conn: a,
  message text: String,
) -> actor.Next(fiber.RpcMessage, fiber.RpcConnection(a, b)) {
  case message.decode(text) {
    Error(error) -> {
      case error {
        json.UnexpectedFormat(_) ->
          message.ErrorData(
            code: -32_600,
            message: "Invalid Request",
            data: option.None,
          )
        json.UnexpectedByte(byte) ->
          message.ErrorData(
            code: -32_700,
            message: "Parse error",
            data: option.Some(json.string("Unexpected Byte: \"" <> byte <> "\"")),
          )

        json.UnexpectedEndOfInput ->
          message.ErrorData(
            code: -32_700,
            message: "Parse error",
            data: option.Some(json.string("Unexpected End of Input")),
          )
        json.UnexpectedSequence(sequence) ->
          message.ErrorData(
            code: -32_700,
            message: "Parse error",
            data: option.Some(json.string(
              "Unexpected Sequence: \"" <> sequence <> "\"",
            )),
          )
      }
      |> message.ErrorMessage
      |> message.encode
      |> json.to_string
      |> rpc.send(conn, _)
      |> stop_on_error(rpc)
    }
    Ok(message) -> handle_message(rpc, conn, message)
  }
}

pub fn handle_rpc_message(
  rpc: fiber.RpcConnection(a, b),
  conn: a,
  message rpc_message: fiber.RpcMessage,
) -> actor.Next(fiber.RpcMessage, fiber.RpcConnection(a, b)) {
  case rpc_message {
    fiber.RpcRequest(method, params, id, reply_subject) -> {
      message.Request(params, method, id)
      |> message.RequestMessage
      |> message.encode
      |> json.to_string
      |> rpc.send(conn, _)
      |> stop_on_error(rpc |> add_waiting(id, reply_subject))
    }
    fiber.RpcNotification(method, params) -> {
      message.Notification(params, method)
      |> message.RequestMessage
      |> message.encode
      |> json.to_string
      |> rpc.send(conn, _)
      |> stop_on_error(rpc)
    }
    fiber.RpcBatch(batch, ids, reply_subject) -> {
      batch
      |> list.map(fn(request) {
        let #(method, params, id) = request
        case id {
          option.None -> message.Notification(params, method)
          option.Some(id) -> message.Request(params, method, id)
        }
      })
      |> message.BatchRequestMessage
      |> message.encode
      |> json.to_string
      |> rpc.send(conn, _)
      |> stop_on_error(rpc |> add_waiting_batch(ids, reply_subject))
    }
    fiber.RpcRemoveWaiting(id) -> actor.continue(rpc |> remove_waiting(id))
    fiber.RpcRemoveWaitingBatch(ids) ->
      actor.continue(rpc |> remove_waiting_batch(ids))
    fiber.Close -> actor.Stop(process.Normal)
  }
}

pub fn handle_binary(
  rpc: fiber.RpcConnection(a, b),
  conn: a,
  message _binary: BitArray,
) -> actor.Next(fiber.RpcMessage, fiber.RpcConnection(a, b)) {
  message.ErrorData(
    code: -32_700,
    message: "Parse error",
    data: option.Some(json.string("binary frames are unsupported")),
  )
  |> message.ErrorMessage
  |> message.encode
  |> json.to_string
  |> rpc.send(conn, _)
  |> stop_on_error(rpc)
}

fn handle_request_callback_result(
  result: Result(Json, fiber.RpcError),
  id: message.Id,
) -> message.Response(Json) {
  case result {
    Error(fiber.InvalidParams) -> {
      option.None
      |> message.ErrorData(code: -32_602, message: "Invalid params")
      |> message.ErrorResponse(id:)
    }
    Error(fiber.InternalError) -> {
      option.None
      |> message.ErrorData(code: -32_603, message: "Internal error")
      |> message.ErrorResponse(id:)
    }
    Error(fiber.CustomError(error)) -> {
      error
      |> message.ErrorResponse(id:)
    }
    Ok(result) -> {
      result
      |> message.SuccessResponse(id:)
    }
  }
}

fn process_request(
  rpc: fiber.RpcConnection(conn, send_error),
  request: message.Request(Dynamic),
) -> Result(message.Response(Json), Nil) {
  case request {
    message.Notification(params, method) ->
      case rpc.notifications |> dict.get(method) {
        Error(Nil) -> {
          // simply ignore  and log unknown notifications, as the spec says never to reply to them
          io.println_error(
            "Received notification we don't have a handler for: "
            <> method
            <> ", params: "
            <> string.inspect(params),
          )
          Error(Nil)
        }
        Ok(callback) -> {
          callback(params)
          Error(Nil)
        }
      }
    message.Request(params, method, id) ->
      case rpc.methods |> dict.get(method) {
        Error(Nil) -> {
          option.Some(json.string(method))
          |> message.ErrorData(code: -32_601, message: "Method not found")
          |> message.ErrorResponse(id:)
          |> Ok
        }
        Ok(callback) -> {
          callback(params)
          |> handle_request_callback_result(id)
          |> Ok
        }
      }
  }
}

fn handle_request(
  rpc: fiber.RpcConnection(a, b),
  conn: a,
  request: message.Request(Dynamic),
) -> actor.Next(fiber.RpcMessage, fiber.RpcConnection(a, b)) {
  case process_request(rpc, request) {
    Error(Nil) -> actor.continue(rpc)
    Ok(response) ->
      response
      |> message.ResponseMessage
      |> message.encode
      |> json.to_string
      |> rpc.send(conn, _)
      |> stop_on_error(rpc)
  }
}

fn handle_response(
  rpc: fiber.RpcConnection(a, b),
  _conn: a,
  response: message.Response(Dynamic),
) -> actor.Next(fiber.RpcMessage, fiber.RpcConnection(a, b)) {
  case response {
    message.ErrorResponse(error, id) ->
      case rpc.waiting |> dict.get(id) {
        Error(Nil) -> {
          // we can't reply to this, so just log an error
          io.println_error(
            "Received error for id that we were not waiting for (it possibly timed out): "
            <> string.inspect(id)
            <> ", error: "
            <> string.inspect(error),
          )

          actor.continue(rpc)
        }
        Ok(reply_subject) -> {
          reply_subject |> process.send(Error(error))

          actor.continue(rpc)
        }
      }
    message.SuccessResponse(result, id) ->
      case rpc.waiting |> dict.get(id) {
        Error(Nil) -> {
          // we can't reply to this, so just log an error
          io.println_error(
            "Received response for id that we were not waiting for (it possibly timed out): "
            <> string.inspect(id)
            <> ", result: "
            <> string.inspect(result),
          )

          actor.continue(rpc)
        }
        Ok(reply_subject) -> {
          reply_subject |> process.send(Ok(result))

          actor.continue(rpc)
        }
      }
  }
}

fn handle_batch_request(
  rpc: fiber.RpcConnection(a, b),
  conn: a,
  batch: List(message.Request(Dynamic)),
) -> actor.Next(fiber.RpcMessage, fiber.RpcConnection(a, b)) {
  batch
  |> list.map(process_request(rpc, _))
  |> result.values
  |> message.BatchResponseMessage
  |> message.encode
  |> json.to_string
  |> rpc.send(conn, _)
  |> stop_on_error(rpc)
}

fn handle_batch_response(
  rpc: fiber.RpcConnection(a, b),
  _conn: a,
  batch: List(message.Response(Dynamic)),
) -> actor.Next(fiber.RpcMessage, fiber.RpcConnection(a, b)) {
  let ids =
    batch
    |> list.map(fn(response) {
      case response {
        message.ErrorResponse(_, id) -> id
        message.SuccessResponse(_, id) -> id
      }
    })
    |> set.from_list

  case rpc.waiting_batches |> dict.get(ids) {
    Error(Nil) -> {
      // we can't reply to this, so just log an error
      io.println_error(
        "Received batch response for an id set that we were not waiting for (it possibly timed out): "
        <> string.inspect(ids),
      )

      actor.continue(rpc)
    }
    Ok(reply_subject) -> {
      batch
      |> list.map(fn(response) {
        case response {
          message.ErrorResponse(error, id) -> #(id, Error(error))
          message.SuccessResponse(result, id) -> #(id, Ok(result))
        }
      })
      |> dict.from_list
      |> process.send(reply_subject, _)

      actor.continue(rpc)
    }
  }
}

fn handle_message(
  rpc: fiber.RpcConnection(a, b),
  conn: a,
  message fiber_message: message.Message(Dynamic),
) -> actor.Next(fiber.RpcMessage, fiber.RpcConnection(a, b)) {
  case fiber_message {
    message.BatchRequestMessage(batch) -> handle_batch_request(rpc, conn, batch)
    message.BatchResponseMessage(batch) ->
      handle_batch_response(rpc, conn, batch)
    message.RequestMessage(request) -> handle_request(rpc, conn, request)
    message.ResponseMessage(response) -> handle_response(rpc, conn, response)
    message.ErrorMessage(error) -> {
      // we can't reply to this according to the spec, so just log an error
      io.println_error(
        "Received error without id (usually indicates we sent malformed data): "
        <> string.inspect(error),
      )

      actor.continue(rpc)
    }
  }
}

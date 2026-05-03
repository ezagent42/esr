defmodule Esr.Interface.Operation do
  @moduledoc """
  Operation contract: enqueue / execute / report admin-style operations.

  Implementers in ESR (post-R4):
    - `Esr.Admin.Dispatcher` (consumes admin queue, executes commands,
       reports results via cleanup signals)

  Future R7 may split Dispatcher; the resulting modules retain this
  contract.

  See session.md §七 (OperationInterface) and `docs/notes/structural-refactor-plan-r4-r11.md` §四-R4/R7.
  """

  @doc "Enqueue an operation for asynchronous execution."
  @callback enqueue(op :: map()) :: {:ok, op_id :: term()} | {:error, term()}

  @doc "Execute an operation synchronously (caller blocks until complete)."
  @callback execute(op :: map(), ctx :: map()) :: :ok | {:ok, term()} | {:error, term()}

  @doc "Report the outcome of an operation (e.g., for tracing or follow-up signals)."
  @callback report(op_id :: term(), result :: term()) :: :ok
end

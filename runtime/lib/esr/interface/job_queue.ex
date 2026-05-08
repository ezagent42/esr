defmodule Esr.Interface.JobQueue do
  @moduledoc """
  FIFO job queue contract: producers enqueue work items, consumers
  dequeue + execute, optionally reporting completion.

  Implementers in ESR (post-R4):
    - `Esr.Resource.DeadLetter.Queue` (failed-to-route envelopes;
       bounded FIFO; consumers may inspect for debugging)

  Future implementers (planned but not in R4-R11):
    - `Esr.Resource.AdminQueue` (admin commands; currently
       `Esr.Admin.CommandQueue.*`, may move under Resource per
       rename-map decision)

  See session.md §六 (JobQueue base) and `docs/notes/structural-refactor-plan-r4-r11.md` §四-R4.
  """

  @doc "Enqueue a job. Returns an id for later report/lookup."
  @callback enqueue(job :: term()) :: {:ok, job_id :: term()} | {:error, term()}

  @doc "Dequeue the next job (FIFO). Returns `:empty` when queue has no work."
  @callback dequeue() :: {:ok, job_id :: term(), job :: term()} | :empty

  @doc "Report completion of a job. Optional for fire-and-forget queues."
  @callback report(job_id :: term(), result :: term()) :: :ok
end

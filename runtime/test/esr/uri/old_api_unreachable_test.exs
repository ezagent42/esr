defmodule Esr.Uri.OldApiUnreachableTest do
  @moduledoc """
  Locks the structural enforcement: deleted registries must NOT compile.
  Future PR re-introducing them = this test fails.

  Spec: docs/superpowers/specs/2026-05-12-uri-identity-design.md §11.4
  Plan: docs/superpowers/plans/2026-05-12-uri-identity-plan.md PR-5 Task 5.2

  ## Coverage

  Asserts the 6 registry modules deleted across PR-1..PR-3 are gone:
    * `Esr.Entity.User.Registry`        — PR-1
    * `Esr.Entity.User.NameIndex`       — PR-1
    * `Esr.Resource.Workspace.Registry` — PR-2
    * `Esr.Resource.Workspace.NameIndex`— PR-2
    * `Esr.Resource.Session.Registry`   — PR-3
    * `Esr.Session.NameIndex.Registry`  — PR-3

  ## Deferred (tracked in docs/futures/todo.md)

  `Esr.Entity.Agent.InstanceRegistry` and `Esr.Uri.Compat` are not yet
  removed — InstanceRegistry still owns the atomic add+spawn supervision
  semantics PR-4 deferred, and Compat is the documented stable migration
  helper module (~80 callers). Both deletions are scoped to a follow-up
  PR (`uri-cleanup-finalize`). When that PR lands, add the two missing
  `Code.ensure_compiled` assertions here.
  """
  use ExUnit.Case, async: true

  test "Esr.Entity.User.Registry is deleted" do
    assert {:error, :nofile} = Code.ensure_compiled(Esr.Entity.User.Registry)
  end

  test "Esr.Entity.User.NameIndex is deleted" do
    assert {:error, :nofile} = Code.ensure_compiled(Esr.Entity.User.NameIndex)
  end

  test "Esr.Resource.Workspace.Registry is deleted" do
    assert {:error, :nofile} = Code.ensure_compiled(Esr.Resource.Workspace.Registry)
  end

  test "Esr.Resource.Workspace.NameIndex is deleted" do
    assert {:error, :nofile} = Code.ensure_compiled(Esr.Resource.Workspace.NameIndex)
  end

  test "Esr.Resource.Session.Registry is deleted" do
    assert {:error, :nofile} = Code.ensure_compiled(Esr.Resource.Session.Registry)
  end

  test "Esr.Session.NameIndex.Registry is deleted" do
    assert {:error, :nofile} = Code.ensure_compiled(Esr.Session.NameIndex.Registry)
  end
end

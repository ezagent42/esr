defmodule Esr.WorktreeTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    # Build a real, throwaway git repo so we can exercise `git worktree`
    # against it. Skipping these tests in CI's lightweight pass via the
    # :integration tag — but they DO run in `mix test` by default unless
    # the tag is excluded, so the worktree subsystem gets coverage.
    tmp = Path.join(System.tmp_dir!(), "esr-worktree-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    root = Path.join(tmp, "main-repo")
    File.mkdir_p!(root)
    {_, 0} = System.cmd("git", ["-C", root, "init", "--initial-branch=main"], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["-C", root, "config", "user.email", "test@example.com"],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd("git", ["-C", root, "config", "user.name", "test"], stderr_to_stdout: true)

    File.write!(Path.join(root, "README"), "hi\n")
    {_, 0} = System.cmd("git", ["-C", root, "add", "."], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["-C", root, "commit", "-m", "init"], stderr_to_stdout: true)

    # Create a fake `origin/main` ref by tagging the current HEAD as
    # `refs/remotes/origin/main`; the production code uses `origin/main`
    # as the fork base, so the test must provide it.
    {_, 0} =
      System.cmd("git", ["-C", root, "update-ref", "refs/remotes/origin/main", "HEAD"],
        stderr_to_stdout: true
      )

    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, tmp: tmp, root: root}
  end

  test "add/3 creates a new worktree forked from origin/main", %{tmp: tmp, root: root} do
    cwd = Path.join(tmp, "wt-feature")

    assert :ok = Esr.Worktree.add(root, "feature-foo", cwd)
    assert File.dir?(cwd)
    assert File.exists?(Path.join(cwd, "README"))

    {branches, 0} =
      System.cmd("git", ["-C", root, "branch", "--list"], stderr_to_stdout: true)

    assert branches =~ "feature-foo"
  end

  test "add/3 errors when cwd already exists", %{tmp: tmp, root: root} do
    cwd = Path.join(tmp, "wt-existing")
    File.mkdir_p!(cwd)

    assert {:error, {:already_exists, ^cwd}} = Esr.Worktree.add(root, "x", cwd)
  end

  test "add/3 errors when root is missing or not a repo", %{tmp: tmp} do
    cwd = Path.join(tmp, "wt-x")
    bogus_root = Path.join(tmp, "does-not-exist")
    assert {:error, :root_missing} = Esr.Worktree.add(bogus_root, "x", cwd)

    plain_dir = Path.join(tmp, "plain")
    File.mkdir_p!(plain_dir)
    assert {:error, :root_not_a_repo} = Esr.Worktree.add(plain_dir, "x", cwd)
  end

  test "status/1 returns :clean for a fresh worktree", %{tmp: tmp, root: root} do
    cwd = Path.join(tmp, "wt-clean")
    :ok = Esr.Worktree.add(root, "clean-branch", cwd)

    assert {:ok, :clean} = Esr.Worktree.status(cwd)
  end

  test "status/1 returns :dirty after an uncommitted edit", %{tmp: tmp, root: root} do
    cwd = Path.join(tmp, "wt-dirty")
    :ok = Esr.Worktree.add(root, "dirty-branch", cwd)
    File.write!(Path.join(cwd, "untracked"), "scratch\n")

    assert {:ok, :dirty} = Esr.Worktree.status(cwd)
  end

  test "remove/3 with force: false fails on dirty, ok on clean", %{tmp: tmp, root: root} do
    cwd = Path.join(tmp, "wt-rm-dirty")
    :ok = Esr.Worktree.add(root, "rm-dirty", cwd)
    File.write!(Path.join(cwd, "scratch"), "x\n")

    assert {:error, {:git_failed, _, _}} = Esr.Worktree.remove(root, cwd, force: false)
    assert File.dir?(cwd)

    cwd2 = Path.join(tmp, "wt-rm-clean")
    :ok = Esr.Worktree.add(root, "rm-clean", cwd2)
    assert :ok = Esr.Worktree.remove(root, cwd2, force: false)
    refute File.dir?(cwd2)
  end

  test "remove/3 with force: true cleans dirty too", %{tmp: tmp, root: root} do
    cwd = Path.join(tmp, "wt-rm-force")
    :ok = Esr.Worktree.add(root, "rm-force", cwd)
    File.write!(Path.join(cwd, "scratch"), "x\n")

    assert :ok = Esr.Worktree.remove(root, cwd, force: true)
    refute File.dir?(cwd)
  end
end

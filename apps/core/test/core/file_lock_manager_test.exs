defmodule Core.FileLockManagerTest do
  use ExUnit.Case, async: true

  alias Core.FileLockManager

  test "with_lock_file removes lock file after successful work" do
    path = tmp_path()

    assert {:ok, :done} = FileLockManager.with_lock_file(path, fn -> :done end)
    refute File.exists?(path <> ".lock")
  end

  test "with_lock_file returns a tagged timeout while another process holds the lock" do
    path = tmp_path()
    parent = self()

    task =
      Task.async(fn ->
        FileLockManager.with_lock_file(path, fn ->
          send(parent, :lock_held)

          receive do
            :release_lock -> :released
          end
        end)
      end)

    assert_receive :lock_held

    assert {:error, {:file_lock_timeout, lock_path}} =
             FileLockManager.with_lock_file(path, fn -> :blocked end,
               retry_count: 1,
               retry_sleep_ms: 1
             )

    assert lock_path == path <> ".lock"

    send(task.pid, :release_lock)
    assert {:ok, :released} = Task.await(task)
  end

  defp tmp_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "core-file-lock-manager-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".lock")
    end)

    path
  end
end

defmodule Structural.Index do
  @moduledoc """
  SQLite-backed store of parsed symbols for a workspace.

  A single GenServer owns the SQLite connection and serializes all access, so
  concurrent structural tool calls (the parallel scheduler) cannot corrupt the
  index. Symbols are produced by `Structural.Parser`; this module assigns stable
  ids, resolves parent references, and persists everything.

  ## Lifecycle

  `index_path/3` walks a workspace, parses supported files, and upserts them:
  unchanged files (same `file_hash`) are skipped, changed files have their
  symbols replaced, and files that disappeared are pruned (cascading to their
  symbols). Paths are stored relative to the indexed root, which is kept in
  process state so `fetch/2` can re-read files and verify hashes.

  ## Query API

    * `outline/2` - symbols in one file, in source order.
    * `search/3` - symbols by name (exact or arity-qualified), optional kind.
    * `fetch/2` - a symbol's exact current source slice, or `{:error, :stale}`
      when the file changed since indexing.
    * `status/1` - index coverage counts.

  Call sites (`calls` table) are populated in a later C1 step; the table exists
  now so the schema is stable.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias Structural.Parser

  @ignored_dirs ~w(.git _build deps node_modules .elixir_ls .lexical cover priv/static)

  @type symbol :: %{
          id: String.t(),
          kind: String.t(),
          name: String.t(),
          path: Path.t(),
          start_line: pos_integer(),
          end_line: pos_integer(),
          start_byte: non_neg_integer(),
          end_byte: non_neg_integer(),
          parent_id: String.t() | nil,
          signature: String.t() | nil,
          preview: String.t() | nil
        }

  defstruct conn: nil, root: nil

  @doc """
  Starts the index.

  Options:

    * `:path` - SQLite database path, or `":memory:"` (default).
    * `:root` - workspace root to resolve relative paths (set by `index_path/3`).
    * `:name` - process name (default `#{inspect(__MODULE__)}`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Indexes every supported file under `root`, returning coverage counts.
  """
  @spec index_path(GenServer.server(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def index_path(server \\ __MODULE__, root, opts \\ []) do
    GenServer.call(server, {:index_path, Path.expand(root), opts}, :infinity)
  end

  @doc """
  Returns the symbols in `path` (relative to the indexed root), in source order.
  """
  @spec outline(GenServer.server(), Path.t()) :: {:ok, [symbol()]}
  def outline(server \\ __MODULE__, path) do
    GenServer.call(server, {:outline, path})
  end

  @doc """
  Searches symbols by `name`. Options: `:kind`, `:limit` (default 50).
  """
  @spec search(GenServer.server(), String.t(), keyword()) :: {:ok, [symbol()]}
  def search(server \\ __MODULE__, name, opts \\ []) do
    GenServer.call(server, {:search, name, opts})
  end

  @doc """
  Fetches a symbol's exact current source slice, verifying the file hash.
  """
  @spec fetch(GenServer.server(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :stale | :no_root | term()}
  def fetch(server \\ __MODULE__, symbol_id) do
    GenServer.call(server, {:fetch, symbol_id})
  end

  @doc """
  Finds call sites whose callee matches `name`. Options: `:limit` (default 50).
  """
  @spec callers(GenServer.server(), String.t(), keyword()) :: {:ok, [map()]}
  def callers(server \\ __MODULE__, name, opts \\ []) do
    GenServer.call(server, {:callers, name, opts})
  end

  @doc """
  Returns index coverage counts.
  """
  @spec status(GenServer.server()) :: {:ok, map()}
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, ":memory:")
    {:ok, conn} = Sqlite3.open(path)
    :ok = configure(conn)
    :ok = create_schema(conn)
    {:ok, %__MODULE__{conn: conn, root: Keyword.get(opts, :root)}}
  end

  @impl true
  def handle_call({:index_path, root, opts}, _from, state) do
    counts = reindex(state.conn, root, opts)
    {:reply, {:ok, counts}, %{state | root: root}}
  end

  def handle_call({:outline, path}, _from, state) do
    {:reply, {:ok, select_outline(state.conn, path)}, state}
  end

  def handle_call({:search, name, opts}, _from, state) do
    {:reply, {:ok, select_search(state.conn, name, opts)}, state}
  end

  def handle_call({:fetch, symbol_id}, _from, state) do
    {:reply, fetch_symbol(state, symbol_id), state}
  end

  def handle_call({:callers, name, opts}, _from, state) do
    {:reply, {:ok, select_callers(state.conn, name, opts)}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, {:ok, select_status(state.conn)}, state}
  end

  @impl true
  def terminate(_reason, state) do
    Sqlite3.close(state.conn)
    :ok
  end

  # --- schema ---

  defp configure(conn) do
    Sqlite3.execute(conn, "PRAGMA foreign_keys = ON")
  end

  defp create_schema(conn) do
    Sqlite3.execute(conn, """
    CREATE TABLE IF NOT EXISTS files (
      id INTEGER PRIMARY KEY,
      path TEXT NOT NULL UNIQUE,
      language TEXT NOT NULL,
      file_hash TEXT NOT NULL,
      indexed_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS symbols (
      id TEXT PRIMARY KEY,
      file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
      kind TEXT NOT NULL,
      name TEXT NOT NULL,
      start_line INTEGER NOT NULL,
      end_line INTEGER NOT NULL,
      start_byte INTEGER NOT NULL,
      end_byte INTEGER NOT NULL,
      parent_id TEXT,
      signature TEXT,
      preview TEXT
    );
    CREATE TABLE IF NOT EXISTS calls (
      id INTEGER PRIMARY KEY,
      file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
      caller_symbol_id TEXT,
      callee_name TEXT NOT NULL,
      line INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name);
    CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file_id);
    CREATE INDEX IF NOT EXISTS idx_calls_callee ON calls(callee_name);
    """)
  end

  # --- indexing ---

  defp reindex(conn, root, opts) do
    files = list_source_files(root, opts)

    :ok = Sqlite3.execute(conn, "BEGIN")
    Enum.each(files, &index_file(conn, root, &1))
    prune_missing(conn, Enum.map(files, & &1.rel))
    :ok = Sqlite3.execute(conn, "COMMIT")

    select_status(conn)
  end

  defp index_file(conn, root, %{rel: rel, language: language}) do
    abs = Path.join(root, rel)

    case File.read(abs) do
      {:ok, content} -> store_file(conn, rel, language, content)
      {:error, _reason} -> :ok
    end
  end

  defp store_file(conn, rel, language, content) do
    hash = sha256(content)

    case file_row(conn, rel) do
      %{file_hash: ^hash} ->
        :ok

      %{id: file_id} ->
        run(conn, "UPDATE files SET language = ?, file_hash = ?, indexed_at = ? WHERE id = ?", [
          to_string(language),
          hash,
          now(),
          file_id
        ])

        run(conn, "DELETE FROM symbols WHERE file_id = ?", [file_id])
        insert_symbols(conn, file_id, rel, content, language)

      nil ->
        run(
          conn,
          "INSERT INTO files (path, language, file_hash, indexed_at) VALUES (?, ?, ?, ?)",
          [
            rel,
            to_string(language),
            hash,
            now()
          ]
        )

        {:ok, file_id} = Sqlite3.last_insert_rowid(conn)
        insert_symbols(conn, file_id, rel, content, language)
    end
  end

  defp insert_symbols(conn, file_id, rel, content, language) do
    case Parser.parse(content, language) do
      {:ok, symbols} ->
        rows = symbol_rows(symbols, rel)
        Enum.each(rows, &insert_symbol(conn, file_id, &1))
        insert_calls(conn, file_id, content, language, rows)

      {:error, _reason} ->
        :ok
    end
  end

  defp insert_calls(conn, file_id, content, language, symbol_rows) do
    case Parser.calls(content, language) do
      {:ok, calls} -> Enum.each(calls, &insert_call(conn, file_id, symbol_rows, &1))
      {:error, _reason} -> :ok
    end
  end

  defp insert_call(conn, file_id, symbol_rows, %{callee: callee, line: line}) do
    run(
      conn,
      "INSERT INTO calls (file_id, caller_symbol_id, callee_name, line) VALUES (?, ?, ?, ?)",
      [file_id, enclosing_symbol_id(symbol_rows, line), callee, line]
    )
  end

  @callable_kinds ~w(function private_function macro method)

  defp enclosing_symbol_id(symbol_rows, line) do
    symbol_rows
    |> Enum.filter(fn row ->
      row.kind in @callable_kinds and row.start_line <= line and line <= row.end_line
    end)
    |> Enum.min_by(fn row -> row.end_line - row.start_line end, fn -> nil end)
    |> case do
      nil -> nil
      row -> row.id
    end
  end

  defp symbol_rows(symbols, rel) do
    with_ids = Enum.map(symbols, fn symbol -> {symbol, symbol_id(rel, symbol)} end)
    name_to_id = Map.new(with_ids, fn {symbol, id} -> {symbol.name, id} end)

    Enum.map(with_ids, fn {symbol, id} ->
      %{
        id: id,
        kind: to_string(symbol.kind),
        name: symbol.name,
        start_line: symbol.start_line,
        end_line: symbol.end_line,
        start_byte: symbol.start_byte,
        end_byte: symbol.end_byte,
        parent_id: symbol.parent && Map.get(name_to_id, symbol.parent),
        signature: symbol.signature,
        preview: symbol.preview
      }
    end)
  end

  defp insert_symbol(conn, file_id, row) do
    run(
      conn,
      """
      INSERT OR REPLACE INTO symbols
        (id, file_id, kind, name, start_line, end_line, start_byte, end_byte, parent_id, signature, preview)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        row.id,
        file_id,
        row.kind,
        row.name,
        row.start_line,
        row.end_line,
        row.start_byte,
        row.end_byte,
        row.parent_id,
        row.signature,
        row.preview
      ]
    )
  end

  defp prune_missing(conn, present_paths) do
    indexed = query(conn, "SELECT path FROM files", []) |> Enum.map(fn [path] -> path end)
    present = MapSet.new(present_paths)

    indexed
    |> Enum.reject(&MapSet.member?(present, &1))
    |> Enum.each(fn path -> run(conn, "DELETE FROM files WHERE path = ?", [path]) end)
  end

  # --- queries ---

  @symbol_columns "id, kind, name, start_line, end_line, start_byte, end_byte, parent_id, signature, preview"

  defp select_outline(conn, path) do
    conn
    |> query(
      """
      SELECT #{@symbol_columns} FROM symbols
        WHERE file_id = (SELECT id FROM files WHERE path = ?)
        ORDER BY start_byte
      """,
      [path]
    )
    |> Enum.map(&row_to_symbol(&1, path))
  end

  defp select_search(conn, name, opts) do
    limit = Keyword.get(opts, :limit, 50)
    {kind_clause, kind_params} = kind_filter(Keyword.get(opts, :kind))

    query(
      conn,
      """
      SELECT s.#{Enum.join(symbol_columns_list(), ", s.")}, f.path
        FROM symbols s JOIN files f ON f.id = s.file_id
        WHERE (s.name = ? OR s.name LIKE ?)#{kind_clause}
        ORDER BY f.path, s.start_byte
        LIMIT ?
      """,
      [name, name <> "/%"] ++ kind_params ++ [limit]
    )
    |> Enum.map(&row_to_search_symbol/1)
  end

  defp kind_filter(nil), do: {"", []}
  defp kind_filter(kind), do: {" AND s.kind = ?", [to_string(kind)]}

  defp select_callers(conn, name, opts) do
    limit = Keyword.get(opts, :limit, 50)

    conn
    |> query(
      """
      SELECT f.path, c.line, c.callee_name, s.name
        FROM calls c
        JOIN files f ON f.id = c.file_id
        LEFT JOIN symbols s ON s.id = c.caller_symbol_id
        WHERE c.callee_name = ?
        ORDER BY f.path, c.line
        LIMIT ?
      """,
      [name, limit]
    )
    |> Enum.map(fn [path, line, callee, caller] ->
      %{path: path, line: line, callee: callee, caller: caller}
    end)
  end

  defp fetch_symbol(%{root: nil}, _symbol_id), do: {:error, :no_root}

  defp fetch_symbol(%{conn: conn, root: root}, symbol_id) do
    case query(
           conn,
           """
           SELECT s.#{Enum.join(symbol_columns_list(), ", s.")}, f.path, f.file_hash
             FROM symbols s JOIN files f ON f.id = s.file_id
             WHERE s.id = ?
           """,
           [symbol_id]
         ) do
      [] -> {:error, :not_found}
      [row] -> read_slice(root, row)
    end
  end

  defp read_slice(root, row) do
    {symbol_fields, [path, stored_hash]} = Enum.split(row, length(symbol_columns_list()))
    symbol = row_to_symbol(symbol_fields, path)
    abs = Path.join(root, path)

    with {:ok, content} <- File.read(abs),
         true <- sha256(content) == stored_hash do
      slice = binary_part(content, symbol.start_byte, symbol.end_byte - symbol.start_byte)
      {:ok, Map.merge(symbol, %{content: slice, file_hash: stored_hash})}
    else
      false -> {:error, :stale}
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_status(conn) do
    [[files]] = query(conn, "SELECT COUNT(*) FROM files", [])
    [[symbols]] = query(conn, "SELECT COUNT(*) FROM symbols", [])
    languages = query(conn, "SELECT DISTINCT language FROM files ORDER BY language", [])

    %{
      files: files,
      symbols: symbols,
      languages: Enum.map(languages, fn [language] -> language end),
      indexed: files > 0
    }
  end

  # --- row mapping ---

  defp symbol_columns_list,
    do: ~w(id kind name start_line end_line start_byte end_byte parent_id signature preview)

  defp row_to_symbol(
         [
           id,
           kind,
           name,
           start_line,
           end_line,
           start_byte,
           end_byte,
           parent_id,
           signature,
           preview
         ],
         path
       ) do
    %{
      id: id,
      kind: kind,
      name: name,
      path: path,
      start_line: start_line,
      end_line: end_line,
      start_byte: start_byte,
      end_byte: end_byte,
      parent_id: parent_id,
      signature: signature,
      preview: preview
    }
  end

  defp row_to_search_symbol(row) do
    {symbol_fields, [path]} = Enum.split(row, length(symbol_columns_list()))
    row_to_symbol(symbol_fields, path)
  end

  # --- file walking ---

  defp list_source_files(root, opts) do
    ignored = MapSet.new(@ignored_dirs ++ Keyword.get(opts, :ignore, []))
    walk(root, root, ignored, [])
  end

  defp walk(dir, root, ignored, acc) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.reduce(entries, acc, &visit(Path.join(dir, &1), root, ignored, &2))
      {:error, _reason} -> acc
    end
  end

  defp visit(path, root, ignored, acc) do
    cond do
      MapSet.member?(ignored, Path.basename(path)) -> acc
      File.dir?(path) -> walk(path, root, ignored, acc)
      true -> add_source_file(path, root, acc)
    end
  end

  defp add_source_file(path, root, acc) do
    case Parser.language_for(path) do
      {:ok, language} -> [%{rel: Path.relative_to(path, root), language: language} | acc]
      :error -> acc
    end
  end

  # --- sqlite helpers ---

  defp query(conn, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    rows
  end

  defp run(conn, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    :ok
  end

  defp file_row(conn, rel) do
    case query(conn, "SELECT id, file_hash FROM files WHERE path = ?", [rel]) do
      [] -> nil
      [[id, file_hash]] -> %{id: id, file_hash: file_hash}
    end
  end

  defp symbol_id(rel, symbol), do: "#{rel}:#{symbol.kind}:#{symbol.name}@#{symbol.start_byte}"

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp now, do: System.system_time(:second)
end

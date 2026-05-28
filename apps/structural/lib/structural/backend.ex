defmodule Structural.Backend do
  @moduledoc """
  Tree-sitter backed implementation of `Core.Structural.Backend`.

  Maps the structural operations onto `Structural.Index`, returning result maps
  the `Core.Tools.Structural.*` tools already expect (each carries `:output` for
  the model plus structured fields). When no index process is running the
  backend returns `:unavailable`, so the tools degrade to the visible
  `:backend_unavailable` result with no change to the tool or scheduler layers.

  The index process defaults to the registered `Structural.Index`; a caller may
  override it with `:structural_index` in the tool context (used in tests).
  """

  @behaviour Core.Structural.Backend

  alias Structural.Index
  alias Structural.Parser

  @impl true
  def available?, do: Parser.available?()

  @impl true
  def run(operation, args, context) do
    server = index_server(context)

    if running?(server) do
      execute(operation, args, context, server)
    else
      :unavailable
    end
  end

  defp execute(:index_repo, args, context, server) do
    root = Path.expand(Map.get(args, :path, "."), context.workspace_root)
    {:ok, status} = Index.index_path(server, root)

    {:ok, status_result(status, "indexed #{status.files} files, #{status.symbols} symbols")}
  end

  defp execute(:index_status, _args, _context, server) do
    {:ok, status} = Index.status(server)
    summary = if status.indexed, do: "index ready", else: "index empty; run index_repo"
    {:ok, status_result(status, summary)}
  end

  defp execute(:indexed_files, args, _context, server) do
    path = Map.get(args, :path)
    limit = Map.get(args, :limit) || 200
    {:ok, files} = Index.files(server, path: path, limit: limit)

    {:ok,
     %{
       status: :ok,
       path: path,
       files: files,
       output: render_files(files),
       summary: "#{length(files)} indexed files#{path_summary(path)}"
     }}
  end

  defp execute(:indexed_outline, args, _context, server) do
    path = Map.get(args, :path)
    limit = Map.get(args, :limit) || 200
    symbol_limit = Map.get(args, :symbol_limit_per_file) || 200

    {:ok, files} =
      Index.outlines(server, path: path, limit: limit, symbol_limit_per_file: symbol_limit)

    {:ok,
     %{
       status: :ok,
       path: path,
       files: files,
       output: render_outlines(files),
       summary: "#{length(files)} indexed outlines#{path_summary(path)}"
     }}
  end

  defp execute(:ast_outline, args, _context, server) do
    path = Map.fetch!(args, :path)
    {:ok, symbols} = Index.outline(server, path)

    {:ok,
     %{
       status: outline_status(symbols),
       path: path,
       symbols: symbols,
       output: render_symbols(symbols),
       summary: "#{length(symbols)} symbols in #{path}"
     }}
  end

  defp execute(:symbol_search, args, _context, server) do
    query = Map.fetch!(args, :query)
    opts = search_opts(args)
    {:ok, matches} = Index.search(server, query, opts)
    {:ok, match_result(matches, "symbol_search #{query}")}
  end

  defp execute(:definitions, args, _context, server) do
    symbol = Map.fetch!(args, :symbol)
    matches = search_candidates(server, symbol, search_opts(args))
    {:ok, match_result(matches, "definitions of #{symbol}")}
  end

  defp execute(:callers, args, _context, server) do
    symbol = Map.fetch!(args, :symbol)
    opts = args |> Map.take([:path, :limit]) |> Enum.reject(&blank_value?/1)
    {:ok, callers} = Index.callers(server, callee_name(symbol), opts)

    {:ok,
     %{
       status: :ok,
       symbol: symbol,
       callers: callers,
       output: render_callers(callers),
       summary: "#{length(callers)} call sites of #{symbol}"
     }}
  end

  defp execute(:fetch_node, args, _context, server) do
    symbol_id = Map.fetch!(args, :symbol_id)
    {:ok, fetch_result(Index.fetch(server, symbol_id), symbol_id)}
  end

  defp execute(:read_indexed_file, args, _context, server) do
    path = Map.fetch!(args, :path)
    max_bytes = Map.get(args, :max_bytes) || 50_000
    {:ok, indexed_file_result(Index.fetch_file(server, path), path, max_bytes)}
  end

  defp execute(:ast_query, args, _context, server) do
    query = Map.fetch!(args, :query)
    opts = args |> Map.take([:path, :limit]) |> Enum.reject(&blank_value?/1)

    case ast_query_plan(query) do
      {:files, label} ->
        {:ok, files} = Index.files(server, opts)
        {:ok, ast_query_result(:files, label, files, render_files(files))}

      {:symbols, label, symbol_opts} ->
        {:ok, symbols} = Index.symbols(server, opts ++ symbol_opts)
        {:ok, ast_query_result(:symbols, label, symbols, render_matches(symbols))}

      {:search, label, name} ->
        {:ok, symbols} = Index.search(server, name, opts)
        {:ok, ast_query_result(:symbols, label, symbols, render_matches(symbols))}

      {:calls, label, call_opts} ->
        {:ok, calls} = Index.calls(server, opts ++ call_opts)
        {:ok, ast_query_result(:calls, label, calls, render_callers(calls))}

      {:unsupported, label} ->
        {:ok,
         %{
           status: :unsupported_query,
           query: query,
           output: unsupported_query_message(label),
           summary: unsupported_query_message(label)
         }}
    end
  end

  # --- result shaping ---

  defp status_result(status, summary) do
    %{
      status: :ok,
      files: status.files,
      symbols: status.symbols,
      languages: status.languages,
      output:
        "#{status.files} files, #{status.symbols} symbols (#{Enum.join(status.languages, ", ")})",
      summary: summary
    }
  end

  defp outline_status([]), do: :not_indexed
  defp outline_status(_symbols), do: :ok

  defp match_result(matches, summary) do
    %{
      status: :ok,
      matches: matches,
      output: render_matches(matches),
      summary: "#{summary}: #{length(matches)} matches"
    }
  end

  defp fetch_result({:ok, node}, _symbol_id) do
    %{
      status: :ok,
      id: node.id,
      kind: node.kind,
      name: node.name,
      path: node.path,
      start_line: node.start_line,
      end_line: node.end_line,
      signature: node.signature,
      content: node.content,
      output: node.content,
      summary: "#{node.kind} #{node.name} (#{node.path}:#{node.start_line})"
    }
  end

  defp fetch_result({:error, reason}, symbol_id) do
    %{
      status: reason,
      id: symbol_id,
      output: fetch_error_message(reason, symbol_id),
      summary: fetch_error_message(reason, symbol_id)
    }
  end

  defp fetch_error_message(:stale, symbol_id),
    do: "node #{symbol_id} is stale; re-run index_repo"

  defp fetch_error_message(:not_found, symbol_id), do: "no node found for #{symbol_id}"
  defp fetch_error_message(reason, symbol_id), do: "cannot fetch #{symbol_id}: #{inspect(reason)}"

  defp indexed_file_result({:ok, file}, _path, max_bytes) do
    {output, truncated} = truncate_content(file.content, max_bytes)

    %{
      status: :ok,
      path: file.path,
      language: file.language,
      file_hash: file.file_hash,
      bytes: file.bytes,
      truncated: truncated,
      content: output,
      output: output,
      summary: read_file_summary(file.path, file.bytes, truncated)
    }
  end

  defp indexed_file_result({:error, reason}, path, _max_bytes) do
    %{
      status: reason,
      path: path,
      output: indexed_file_error_message(reason, path),
      summary: indexed_file_error_message(reason, path)
    }
  end

  defp indexed_file_error_message(:stale, path),
    do: "indexed file #{path} is stale; re-run index_repo"

  defp indexed_file_error_message(:not_found, path), do: "indexed file not found for #{path}"

  defp indexed_file_error_message(reason, path),
    do: "cannot read indexed file #{path}: #{inspect(reason)}"

  defp read_file_summary(path, bytes, false), do: "read indexed file #{path} (#{bytes} bytes)"

  defp read_file_summary(path, bytes, true),
    do: "read indexed file #{path} (truncated from #{bytes} bytes)"

  defp truncate_content(content, max_bytes) when byte_size(content) <= max_bytes,
    do: {content, false}

  defp truncate_content(content, max_bytes) do
    {binary_part(content, 0, max_bytes), true}
  end

  defp ast_query_result(kind, label, matches, output) do
    %{
      status: :ok,
      query_kind: kind,
      matches: matches,
      output: output,
      summary: "#{label}: #{length(matches)} matches"
    }
  end

  defp unsupported_query_message(label),
    do:
      "unsupported structural query #{inspect(label)}; try source_file, defmodule, def, call, kind:<kind>, or name:<symbol>"

  defp render_files(files) do
    Enum.map_join(files, "\n", fn file ->
      "#{file.path} #{file.language} #{file.symbol_count} symbols"
    end)
  end

  defp render_outlines(files) do
    Enum.map_join(files, "\n", fn file ->
      file.symbols
      |> Enum.map_join("\n", &"  #{render_symbol(&1)}")
      |> case do
        "" -> render_file_header(file)
        symbols -> render_file_header(file) <> "\n" <> symbols
      end
    end)
  end

  defp render_file_header(file), do: "#{file.path} #{file.language} #{file.symbol_count} symbols"

  defp render_symbols(symbols) do
    Enum.map_join(symbols, "\n", &render_symbol/1)
  end

  defp render_matches(matches) do
    Enum.map_join(matches, "\n", fn match ->
      "#{match.path}:#{match.start_line} #{match.kind} #{match.name} id=#{match.id}"
    end)
  end

  defp render_symbol(symbol) do
    "#{symbol.kind} #{symbol.name} id=#{symbol.id} (lines #{symbol.start_line}-#{symbol.end_line})"
  end

  defp render_callers(callers) do
    Enum.map_join(callers, "\n", fn caller ->
      "#{caller.path}:#{caller.line} #{in_caller(caller.caller)}"
    end)
  end

  defp in_caller(nil), do: "(top level)"
  defp in_caller(name), do: "(in #{name})"

  # --- name resolution ---

  defp search_candidates(server, symbol, opts) do
    symbol
    |> candidate_names()
    |> Enum.flat_map(fn name ->
      {:ok, matches} = Index.search(server, name, opts)
      matches
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp candidate_names(symbol) do
    base = String.replace(symbol, ~r"/\d+$", "")
    Enum.uniq([base, last_segment(base)])
  end

  defp callee_name(symbol), do: symbol |> String.replace(~r"/\d+$", "") |> last_segment()

  defp last_segment(name), do: name |> String.split(".") |> List.last()

  # --- compact structural query DSL ---

  defp ast_query_plan(query) do
    downcased = String.downcase(query)

    cond do
      source_file_query?(downcased) ->
        {:files, query}

      call_query?(downcased) ->
        {:calls, query, call_opts(query)}

      kind = explicit_kind(query) ->
        {:symbols, query, [kind: kind]}

      name = explicit_name(query) ->
        {:search, query, name}

      module_query?(downcased) ->
        {:symbols, query, [kind: "module"]}

      private_function_query?(downcased) ->
        {:symbols, query, [kind: "private_function"]}

      macro_query?(downcased) ->
        {:symbols, query, [kind: "macro"]}

      function_query?(downcased) ->
        {:symbols, query, [kinds: ["function", "private_function", "macro"]]}

      true ->
        {:unsupported, query}
    end
  end

  defp source_file_query?(query),
    do: String.contains?(query, "source_file") or query in ["file", "files"]

  defp call_query?(query), do: String.contains?(query, "call")

  defp module_query?(query),
    do: String.contains?(query, "defmodule") or String.contains?(query, "module")

  defp private_function_query?(query),
    do: String.contains?(query, "defp") or String.contains?(query, "private_function")

  defp macro_query?(query),
    do: String.contains?(query, "defmacro") or String.contains?(query, "macro")

  defp function_query?(query),
    do: String.contains?(query, "def") or String.contains?(query, "function")

  defp explicit_kind(query) do
    case Regex.run(~r/(?:kind|type):([A-Za-z_]+)/, query) do
      [_match, kind] -> kind
      nil -> nil
    end
  end

  defp explicit_name(query) do
    case Regex.run(~r/name:([A-Za-z0-9_.!?\/]+)/, query) do
      [_match, name] -> name
      nil -> nil
    end
  end

  defp call_opts(query) do
    case Regex.run(~r/(?:callee|name):([A-Za-z0-9_.!?\/]+)/, query) do
      [_match, callee] -> [callee: callee]
      nil -> []
    end
  end

  defp search_opts(args) do
    args
    |> Map.take([:kind, :path, :limit])
    |> Enum.reject(&blank_value?/1)
  end

  defp blank_value?({_key, nil}), do: true
  defp blank_value?({_key, ""}), do: true
  defp blank_value?(_pair), do: false

  defp path_summary(nil), do: ""
  defp path_summary(""), do: ""
  defp path_summary(path), do: " under #{path}"

  # --- index process ---

  defp index_server(context), do: Map.get(context, :structural_index, Index)

  defp running?(server) when is_pid(server), do: Process.alive?(server)
  defp running?(server), do: Process.whereis(server) != nil
end

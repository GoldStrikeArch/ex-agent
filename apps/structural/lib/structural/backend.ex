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
    {:ok, matches} = Index.search(server, query, kind: Map.get(args, :kind))
    {:ok, match_result(matches, "symbol_search #{query}")}
  end

  defp execute(:definitions, args, _context, server) do
    symbol = Map.fetch!(args, :symbol)
    matches = search_candidates(server, symbol)
    {:ok, match_result(matches, "definitions of #{symbol}")}
  end

  defp execute(:callers, args, _context, server) do
    symbol = Map.fetch!(args, :symbol)
    {:ok, callers} = Index.callers(server, callee_name(symbol))

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

  defp execute(:ast_query, _args, _context, _server), do: {:error, :unsupported_query}

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

  defp render_symbols(symbols) do
    Enum.map_join(symbols, "\n", fn symbol ->
      "#{symbol.kind} #{symbol.name} (lines #{symbol.start_line}-#{symbol.end_line})"
    end)
  end

  defp render_matches(matches) do
    Enum.map_join(matches, "\n", fn match ->
      "#{match.path}:#{match.start_line} #{match.kind} #{match.name}"
    end)
  end

  defp render_callers(callers) do
    Enum.map_join(callers, "\n", fn caller ->
      "#{caller.path}:#{caller.line} #{in_caller(caller.caller)}"
    end)
  end

  defp in_caller(nil), do: "(top level)"
  defp in_caller(name), do: "(in #{name})"

  # --- name resolution ---

  defp search_candidates(server, symbol) do
    symbol
    |> candidate_names()
    |> Enum.flat_map(fn name ->
      {:ok, matches} = Index.search(server, name)
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

  # --- index process ---

  defp index_server(context), do: Map.get(context, :structural_index, Index)

  defp running?(server) when is_pid(server), do: Process.alive?(server)
  defp running?(server), do: Process.whereis(server) != nil
end

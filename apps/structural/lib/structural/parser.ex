defmodule Structural.Parser do
  @moduledoc """
  Parses source into normalized `Structural.Symbol`s.

  Strategy is per language, because the `tree_sitter_language_pack` NIF only
  exposes a working high-level analyzer (`process/2`) for some languages and its
  low-level tree API is not implemented in the precompiled build:

    * Python / TypeScript / JavaScript → `TreeSitterLanguagePack.process/2`,
      whose `structure` carries names, kinds, and byte/line spans.
    * Elixir → the BEAM's own `Code.string_to_quoted/2`. `process/2` returns
      nothing for Elixir, and Elixir is the language we most need to ground, so
      we use the native parser, which is dependency-free and accurate.

  `parse/2` is pure over its `source` argument. The index assigns `:path`,
  `:file_hash`, `:id`, and `:parent_id` later; the parser fills the
  source-derived fields and `:parent` (the enclosing symbol's name).
  """

  alias Structural.Symbol

  @extensions %{
    ".ex" => :elixir,
    ".exs" => :elixir,
    ".py" => :python,
    ".ts" => :typescript,
    ".tsx" => :tsx,
    ".js" => :javascript,
    ".jsx" => :javascript,
    ".mjs" => :javascript,
    ".cjs" => :javascript
  }

  @pack_languages %{
    python: "python",
    typescript: "typescript",
    tsx: "tsx",
    javascript: "javascript"
  }

  @def_ops %{
    def: :function,
    defp: :private_function,
    defmacro: :macro,
    defmacrop: :macro
  }

  @preview_limit 200

  @typedoc "Supported source language."
  @type language :: :elixir | :python | :typescript | :tsx | :javascript

  @doc """
  Reports whether the Tree-sitter NIF is loaded.

  Elixir parsing never depends on the NIF, but the other languages do.
  """
  @spec available?() :: boolean()
  def available? do
    TreeSitterLanguagePack.has_language("python")
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  @doc """
  Detects a supported language from a file path's extension.
  """
  @spec language_for(Path.t()) :: {:ok, language()} | :error
  def language_for(path) when is_binary(path) do
    Map.fetch(@extensions, path |> Path.extname() |> String.downcase())
  end

  @doc """
  Returns the distinct supported languages.
  """
  @spec supported_languages() :: [language()]
  def supported_languages, do: @extensions |> Map.values() |> Enum.uniq()

  @doc """
  Parses `source` written in `language` into normalized symbols.
  """
  @spec parse(binary(), language()) :: {:ok, [Symbol.t()]} | {:error, term()}
  def parse(source, :elixir) when is_binary(source), do: parse_elixir(source)

  def parse(source, language) when is_binary(source) and is_map_key(@pack_languages, language) do
    parse_via_pack(source, Map.fetch!(@pack_languages, language))
  end

  def parse(_source, language), do: {:error, {:unsupported_language, language}}

  @doc """
  Extracts simple call sites from `source`.

  Each call is `%{callee: name, line: line}`. Only unambiguous Elixir remote
  calls (`Mod.fun(...)`) are extracted, which avoids the operator/macro noise of
  local-call heuristics. Other languages return `{:ok, []}` until call
  extraction is added for them.
  """
  @spec calls(binary(), language()) ::
          {:ok, [%{callee: String.t(), line: pos_integer()}]} | {:error, term()}
  def calls(source, :elixir) when is_binary(source) do
    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} ->
        {_ast, calls} = Macro.prewalk(ast, [], &collect_remote_call/2)
        {:ok, Enum.reverse(calls)}

      {:error, reason} ->
        {:error, {:parse_failed, reason}}
    end
  end

  def calls(source, language) when is_binary(source) and is_map_key(@pack_languages, language) do
    {:ok, []}
  end

  def calls(_source, language), do: {:error, {:unsupported_language, language}}

  defp collect_remote_call({{:., _dot_meta, [_module, fun]}, meta, args} = node, acc)
       when is_atom(fun) and is_list(args) do
    {node, [%{callee: Atom.to_string(fun), line: Keyword.get(meta, :line, 1)} | acc]}
  end

  defp collect_remote_call(node, acc), do: {node, acc}

  # --- Tree-sitter language pack path (Python / TS / JS) ---

  defp parse_via_pack(source, pack_language) do
    config = Core.Json.encode!(%{language: pack_language})

    case TreeSitterLanguagePack.process(source, config) do
      {:ok, result} ->
        {:ok, flatten_structure(Map.get(result, :structure, []), source, nil)}

      {:error, _kind, message} ->
        {:error, {:parse_failed, message}}
    end
  rescue
    exception -> {:error, {:parser_exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:parser_crash, kind, reason}}
  end

  defp flatten_structure(items, source, parent) when is_list(items) do
    Enum.flat_map(items, fn item ->
      symbol = structure_symbol(item, source, parent)
      [symbol | flatten_structure(Map.get(item, :children, []), source, symbol.name)]
    end)
  end

  defp structure_symbol(item, source, parent) do
    span = Map.get(item, :span) || %{}
    start_byte = Map.get(span, :start_byte, 0)
    end_byte = max(Map.get(span, :end_byte, start_byte), start_byte)

    %Symbol{
      kind: structure_kind(Map.get(item, :kind)),
      name: Map.get(item, :name) || "",
      start_line: line(span, :start_line),
      end_line: line(span, :end_line),
      start_byte: start_byte,
      end_byte: end_byte,
      signature: Map.get(item, :signature),
      preview: preview(source, start_byte, end_byte),
      parent: parent
    }
  end

  defp structure_kind(%{format_type: format}) when is_binary(format), do: kind_atom(format)
  defp structure_kind(format) when is_binary(format), do: kind_atom(format)
  defp structure_kind(_kind), do: :other

  defp kind_atom(format) do
    case String.downcase(format) do
      "function" -> :function
      "method" -> :method
      "class" -> :class
      "struct" -> :struct
      "interface" -> :interface
      "module" -> :module
      "trait" -> :interface
      "impl" -> :impl
      _other -> :other
    end
  end

  defp line(span, key), do: Map.get(span, key, 0) + 1

  # --- Elixir path (Code.string_to_quoted) ---

  defp parse_elixir(source) do
    case Code.string_to_quoted(source, columns: true, token_metadata: true) do
      {:ok, ast} ->
        offsets = line_offsets(source)
        {:ok, source |> walk(ast, nil, offsets, []) |> Enum.reverse()}

      {:error, reason} ->
        {:error, {:parse_failed, reason}}
    end
  end

  defp walk(source, {op, meta, [head | _rest]}, parent, offsets, acc)
       when is_map_key(@def_ops, op) do
    [function_symbol(source, op, head, meta, parent, offsets) | acc]
  end

  defp walk(source, {:defmodule, meta, [alias_ast, body]}, _parent, offsets, acc) do
    name = module_name(alias_ast)
    acc = [module_symbol(source, name, meta, offsets) | acc]
    walk(source, Keyword.get(body, :do), name, offsets, acc)
  end

  defp walk(source, {:__block__, _meta, statements}, parent, offsets, acc) do
    Enum.reduce(statements, acc, &walk(source, &1, parent, offsets, &2))
  end

  defp walk(source, list, parent, offsets, acc) when is_list(list) do
    Enum.reduce(list, acc, &walk(source, &1, parent, offsets, &2))
  end

  defp walk(source, {_form, _meta, args}, parent, offsets, acc) when is_list(args) do
    Enum.reduce(args, acc, &walk(source, &1, parent, offsets, &2))
  end

  defp walk(_source, _other, _parent, _offsets, acc), do: acc

  defp module_symbol(source, name, meta, offsets) do
    {start_line, end_line, start_byte, end_byte} = span_from_meta(meta, offsets, source)

    %Symbol{
      kind: :module,
      name: name,
      start_line: start_line,
      end_line: end_line,
      start_byte: start_byte,
      end_byte: end_byte,
      signature: "defmodule #{name}",
      preview: preview(source, start_byte, end_byte),
      parent: nil
    }
  end

  defp function_symbol(source, op, head, meta, parent, offsets) do
    {name, arity} = name_and_arity(head)
    {start_line, end_line, start_byte, end_byte} = span_from_meta(meta, offsets, source)

    %Symbol{
      kind: Map.fetch!(@def_ops, op),
      name: "#{name}/#{arity}",
      start_line: start_line,
      end_line: end_line,
      start_byte: start_byte,
      end_byte: end_byte,
      signature: "#{op} #{Macro.to_string(head)}",
      preview: preview(source, start_byte, end_byte),
      parent: parent
    }
  end

  defp name_and_arity({:when, _meta, [real_head | _guards]}), do: name_and_arity(real_head)

  defp name_and_arity({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp name_and_arity({name, _meta, _context}) when is_atom(name), do: {name, 0}
  defp name_and_arity(other), do: {Macro.to_string(other), 0}

  defp module_name({:__aliases__, _meta, parts}), do: Enum.map_join(parts, ".", &to_string/1)
  defp module_name(name) when is_atom(name), do: inspect(name)
  defp module_name(other), do: Macro.to_string(other)

  defp span_from_meta(meta, offsets, source) do
    start_line = Keyword.get(meta, :line, 1)
    column = Keyword.get(meta, :column, 1)
    end_line = meta_end_line(meta, start_line)

    {start_line, end_line, byte_offset(offsets, start_line, column),
     line_end_byte(offsets, end_line, source)}
  end

  defp meta_end_line(meta, start_line) do
    cond do
      line = get_in(meta, [:end, :line]) -> line
      line = get_in(meta, [:end_of_expression, :line]) -> line
      line = get_in(meta, [:do, :line]) -> line
      true -> start_line
    end
  end

  # --- shared helpers ---

  defp preview(source, start_byte, end_byte)
       when is_binary(source) and end_byte > start_byte and end_byte <= byte_size(source) do
    source
    |> binary_part(start_byte, end_byte - start_byte)
    |> first_line()
  end

  defp preview(_source, _start_byte, _end_byte), do: nil

  defp first_line(text) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, @preview_limit)
  end

  # Maps a 1-based line number to the byte offset of that line's start.
  defp line_offsets(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({%{}, 0}, fn {line, number}, {acc, offset} ->
      {Map.put(acc, number, offset), offset + byte_size(line) + 1}
    end)
    |> elem(0)
  end

  defp byte_offset(offsets, line, column) do
    Map.get(offsets, line, 0) + (column - 1)
  end

  defp line_end_byte(offsets, line, source) do
    case Map.get(offsets, line + 1) do
      nil -> byte_size(source)
      next_start -> next_start - 1
    end
  end
end

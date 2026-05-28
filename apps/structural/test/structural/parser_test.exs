defmodule Structural.ParserTest do
  use ExUnit.Case, async: true

  alias Structural.Parser
  alias Structural.Symbol

  defp names(symbols), do: Enum.map(symbols, & &1.name)
  defp find(symbols, name), do: Enum.find(symbols, &(&1.name == name))

  describe "language_for/1" do
    test "detects supported extensions" do
      assert Parser.language_for("lib/foo.ex") == {:ok, :elixir}
      assert Parser.language_for("x.exs") == {:ok, :elixir}
      assert Parser.language_for("a/b.py") == {:ok, :python}
      assert Parser.language_for("c.ts") == {:ok, :typescript}
      assert Parser.language_for("c.tsx") == {:ok, :tsx}
      assert Parser.language_for("d.js") == {:ok, :javascript}
      assert Parser.language_for("e.jsx") == {:ok, :javascript}
    end

    test "returns :error for unsupported extensions" do
      assert Parser.language_for("README.md") == :error
      assert Parser.language_for("noext") == :error
    end
  end

  test "parser is available (NIF loaded)" do
    assert Parser.available?()
  end

  describe "Elixir (Code.string_to_quoted)" do
    test "extracts modules, functions, private functions, and macros with parents" do
      source = """
      defmodule Foo.Bar do
        @moduledoc "x"
        def hello(a, b), do: a + b

        defp secret do
          :ok
        end

        defmacro mac(x), do: x
      end
      """

      assert {:ok, symbols} = Parser.parse(source, :elixir)

      assert "Foo.Bar" in names(symbols)
      assert "hello/2" in names(symbols)
      assert "secret/0" in names(symbols)
      assert "mac/1" in names(symbols)

      module = find(symbols, "Foo.Bar")
      assert module.kind == :module
      assert module.start_line == 1

      hello = find(symbols, "hello/2")
      assert hello.kind == :function
      assert hello.parent == "Foo.Bar"
      assert hello.signature == "def hello(a, b)"

      assert find(symbols, "secret/0").kind == :private_function
      assert find(symbols, "mac/1").kind == :macro

      # Byte ranges point at the real source slice.
      assert binary_part(source, module.start_byte, 9) == "defmodule"
    end

    test "handles function heads with guards" do
      source = """
      defmodule G do
        def f(x) when is_integer(x), do: x
      end
      """

      assert {:ok, symbols} = Parser.parse(source, :elixir)
      assert "f/1" in names(symbols)
    end

    test "returns a tagged error for invalid source instead of raising" do
      assert {:error, {:parse_failed, _}} = Parser.parse("defmodule Broken do", :elixir)
    end
  end

  describe "Python / TS / JS (tree_sitter_language_pack)" do
    test "extracts python classes, methods, and functions" do
      source = """
      import os

      class Animal:
          def speak(self):
              return "hi"

      def main():
          return Animal()
      """

      assert {:ok, symbols} = Parser.parse(source, :python)
      assert "Animal" in names(symbols)
      assert "main" in names(symbols)

      animal = find(symbols, "Animal")
      assert animal.kind == :class
      assert animal.start_line >= 1
      assert animal.end_byte > animal.start_byte
    end

    test "extracts javascript functions and classes" do
      source = """
      export function add(a, b) { return a + b; }

      class C {
        m() { return 1; }
      }
      """

      assert {:ok, symbols} = Parser.parse(source, :javascript)
      assert "add" in names(symbols)
      assert "C" in names(symbols)
      assert %Symbol{kind: :class} = find(symbols, "C")
    end

    test "extracts typescript declarations" do
      source = """
      export function add(a: number): number { return a; }
      class C { m(): void {} }
      """

      assert {:ok, symbols} = Parser.parse(source, :typescript)
      assert "add" in names(symbols)
      assert "C" in names(symbols)
    end
  end

  test "unsupported languages return a tagged error" do
    assert {:error, {:unsupported_language, :ruby}} = Parser.parse("puts 1", :ruby)
  end
end

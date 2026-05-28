defmodule BloccsTest do
  use ExUnit.Case
  doctest Bloccs

  test "version is reported as a binary" do
    assert is_binary(Bloccs.version())
    assert Bloccs.version() =~ ~r/^\d+\.\d+\.\d+/
  end
end

defmodule Esr.Yaml.WriterTest do
  use ExUnit.Case, async: true
  alias Esr.Yaml.Writer

  test "writes nested map" do
    tmp = Path.join(System.tmp_dir!(), "ytest_#{System.unique_integer([:positive])}.yaml")
    on_exit(fn -> File.rm(tmp) end)

    data = %{"principals" => [%{"id" => "ou_x", "capabilities" => ["*"]}]}
    :ok = Writer.write(tmp, data)
    {:ok, roundtrip} = YamlElixir.read_from_file(tmp)
    assert roundtrip == data
  end

  test "writes lists" do
    tmp = Path.join(System.tmp_dir!(), "ytest_#{System.unique_integer([:positive])}.yaml")
    on_exit(fn -> File.rm(tmp) end)

    data = %{"branches" => [%{"name" => "dev", "port" => 4321}]}
    :ok = Writer.write(tmp, data)
    {:ok, roundtrip} = YamlElixir.read_from_file(tmp)
    assert roundtrip == data
  end

  test "quotes ULID strings correctly" do
    # ULID (26-char Crockford base32) must round-trip as a string, not number
    tmp = Path.join(System.tmp_dir!(), "ytest_#{System.unique_integer([:positive])}.yaml")
    on_exit(fn -> File.rm(tmp) end)

    # All-digit "ULID-ish" string — the dangerous case YAML parsers coerce to int
    data = %{"id" => "01ARZ3NDEKTSV4RRFFQ69G5FAV", "numeric_id" => "0123456789"}
    :ok = Writer.write(tmp, data)
    {:ok, roundtrip} = YamlElixir.read_from_file(tmp)
    assert roundtrip == data
    assert is_binary(roundtrip["numeric_id"])
  end

  test "quotes boolean-looking strings" do
    tmp = Path.join(System.tmp_dir!(), "ytest_#{System.unique_integer([:positive])}.yaml")
    on_exit(fn -> File.rm(tmp) end)

    data = %{
      "bool_str_true" => "true",
      "bool_str_false" => "false",
      "null_str" => "null",
      "yes_str" => "yes",
      "real_bool" => true
    }

    :ok = Writer.write(tmp, data)
    {:ok, roundtrip} = YamlElixir.read_from_file(tmp)
    assert roundtrip == data
    assert is_binary(roundtrip["bool_str_true"])
    assert is_binary(roundtrip["null_str"])
    assert roundtrip["real_bool"] == true
  end

  test "handles special characters in strings" do
    tmp = Path.join(System.tmp_dir!(), "ytest_#{System.unique_integer([:positive])}.yaml")
    on_exit(fn -> File.rm(tmp) end)

    data = %{
      "url" => "https://example.com:8443/path",
      "comment_like" => "value # not a comment",
      "quoted" => ~s(has "quotes" inside),
      "dash_lead" => "-leading-dash",
      "star_lead" => "*starlead",
      "colon_only" => "key: value"
    }

    :ok = Writer.write(tmp, data)
    {:ok, roundtrip} = YamlElixir.read_from_file(tmp)
    assert roundtrip == data
  end

  test "deeper nesting" do
    tmp = Path.join(System.tmp_dir!(), "ytest_#{System.unique_integer([:positive])}.yaml")
    on_exit(fn -> File.rm(tmp) end)

    data = %{
      "routing" => %{
        "principals" => %{
          "ou_abc" => %{
            "active" => "dev",
            "targets" => %{
              "dev" => %{
                "esrd_url" => "http://localhost:4321",
                "cc_session_id" => "sess_123"
              },
              "prod" => %{
                "esrd_url" => "http://localhost:4000",
                "cc_session_id" => "sess_456"
              }
            }
          }
        }
      }
    }

    :ok = Writer.write(tmp, data)
    {:ok, roundtrip} = YamlElixir.read_from_file(tmp)
    assert roundtrip == data
  end
end

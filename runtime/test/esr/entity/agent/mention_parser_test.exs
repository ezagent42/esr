defmodule Esr.Entity.Agent.MentionParserTest do
  use ExUnit.Case, async: true
  alias Esr.Entity.Agent.MentionParser

  @agents ["esr-dev", "alice", "bob-reviewer"]

  # ---------------------------------------------------------------------------
  # Matched mentions
  # ---------------------------------------------------------------------------

  describe "parse/2 — mention matched" do
    test "leading mention: '@esr-dev hello'" do
      assert {:mention, "esr-dev", "hello"} =
               MentionParser.parse("@esr-dev hello", @agents)
    end

    test "leading mention with no trailing text: '@alice'" do
      assert {:mention, "alice", ""} = MentionParser.parse("@alice", @agents)
    end

    test "mid-text mention: 'hey @alice what do you think'" do
      assert {:mention, "alice", "hey what do you think"} =
               MentionParser.parse("hey @alice what do you think", @agents)
    end

    test "mention with dashes in name: '@bob-reviewer please check'" do
      assert {:mention, "bob-reviewer", "please check"} =
               MentionParser.parse("@bob-reviewer please check", @agents)
    end

    test "leading whitespace before @: '  @alice msg'" do
      assert {:mention, "alice", "msg"} =
               MentionParser.parse("  @alice msg", @agents)
    end
  end

  # ---------------------------------------------------------------------------
  # No mention (plain)
  # ---------------------------------------------------------------------------

  describe "parse/2 — no mention (plain)" do
    test "no @ in text" do
      assert {:plain, "just plain text"} =
               MentionParser.parse("just plain text", @agents)
    end

    test "lone @ not followed by identifier" do
      assert {:plain, "@ hello"} = MentionParser.parse("@ hello", @agents)
    end

    test "lone @ at end" do
      assert {:plain, "end @"} = MentionParser.parse("end @", @agents)
    end

    test "@name not in agent list routes to plain" do
      assert {:plain, "@unknown hello"} =
               MentionParser.parse("@unknown hello", @agents)
    end

    test "empty text" do
      assert {:plain, ""} = MentionParser.parse("", @agents)
    end

    test "text is just whitespace" do
      assert {:plain, "   "} = MentionParser.parse("   ", @agents)
    end

    test "email address is not a mention: 'email@alice.com'" do
      # The `@` is preceded by 'l' (alphanumeric) — boundary rule rejects it.
      assert {:plain, "email@alice.com"} =
               MentionParser.parse("email@alice.com", ["alice"])
    end
  end

  # ---------------------------------------------------------------------------
  # Multiple @ patterns
  # ---------------------------------------------------------------------------

  describe "parse/2 — multiple @ patterns" do
    test "first matched @ wins; second is left in rest text" do
      # @alice is matched first; @bob-reviewer stays in the remaining text.
      assert {:mention, "alice", "cc @bob-reviewer too"} =
               MentionParser.parse("@alice cc @bob-reviewer too", @agents)
    end

    test "@unknown first, @alice second: @alice matched (first known agent)" do
      # @unknown is not in list; scan continues; @alice is the first known match.
      assert {:mention, "alice", "@unknown see this"} =
               MentionParser.parse("@unknown @alice see this", @agents)
    end

    test "@alice@bob — @alice matched; stripped text is '@bob'" do
      assert {:mention, "alice", "@bob"} =
               MentionParser.parse("@alice@bob", ["alice", "bob"])
    end
  end

  # ---------------------------------------------------------------------------
  # Empty agent list
  # ---------------------------------------------------------------------------

  describe "parse/2 — empty agent list" do
    test "any @name → plain when no agents registered" do
      assert {:plain, "@alice hello"} = MentionParser.parse("@alice hello", [])
    end
  end
end

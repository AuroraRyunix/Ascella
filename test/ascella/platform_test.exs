defmodule Ascella.PlatformTest do
  use ExUnit.Case, async: true

  alias Ascella.Platform

  describe "target/2" do
    test "an Apple Silicon Mac and an Intel Mac are different targets" do
      assert Platform.target({:unix, :darwin}, "aarch64") == "macos-aarch64"
      assert Platform.target({:unix, :darwin}, "x86_64") == "macos-x86_64"
    end

    test "the others are as before" do
      assert Platform.target({:win32, :nt}, "x86_64") == "windows-x86_64"
      assert Platform.target({:unix, :linux}, "aarch64") == "linux-aarch64"
      assert Platform.target({:unix, :linux}, "x86_64") == "linux-x86_64"
    end

    test "every target it can name is one the catalogue accepts" do
      for target <- [
            Platform.target({:unix, :darwin}, "x86_64"),
            Platform.target({:unix, :darwin}, "aarch64")
          ] do
        assert target in Platform.targets()
      end
    end
  end

  describe "arch/2" do
    test "Apple Silicon, native" do
      assert Platform.arch("aarch64-apple-darwin25.0.0", false) == "aarch64"
      assert Platform.arch("arm64-apple-darwin25.0.0", false) == "aarch64"
    end

    test "Intel, native" do
      assert Platform.arch("x86_64-apple-darwin24.0.0", false) == "x86_64"
    end

    test "an Intel Ascella under Rosetta is on an Apple Silicon machine and wants arm64 builds" do
      assert Platform.arch("x86_64-apple-darwin24.0.0", true) == "aarch64"
    end
  end
end

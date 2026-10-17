defmodule Ascella.CatalogueTest do
  use ExUnit.Case, async: true

  alias Ascella.Catalogue

  defp entry(overrides) do
    Map.merge(
      %{
        "id" => "polis",
        "name" => "Polis",
        "repo" => "AuroraRyunix/Polis",
        "layout" => "hall",
        "mark" => "polis.svg"
      },
      overrides
    )
  end

  defp parse(entries), do: Catalogue.parse!(%{"apps" => entries})

  test "the shipped catalogue loads, with a mark on disk for every app" do
    apps = Catalogue.load!(Application.app_dir(:ascella, "priv/catalogue.json"))
    assert Enum.map(apps, & &1.id) == ~w(openpairings alnasl arkab polis nunki)

    for app <- apps do
      assert File.regular?(Application.app_dir(:ascella, "priv/marks/#{app.mark}")), app.mark
      assert String.starts_with?(app.repo, "AuroraRyunix/")
      assert app.blurb["en"] && app.blurb["nl"]
    end

    pairings = Enum.find(apps, &(&1.id == "openpairings"))

    assert %{method: :velopack, pack_id: "OpenPairingsApp"} =
             Catalogue.spec(pairings, "windows-x86_64")

    assert "{localappdata}/OpenPairingsData" in pairings.data.windows
  end

  test "one entry with the hall layout is a whole app" do
    [app] = parse([entry(%{})])
    windows = Catalogue.spec(app, "windows-x86_64")

    assert %{
             method: :velopack,
             setup: "Polis-Setup.exe",
             pack_id: "PolisApp",
             window_class: "PolisLauncher"
           } = windows

    assert Catalogue.asset(windows, :package, "1.2.3") == "PolisApp-1.2.3-full.nupkg"

    assert %{method: :mac_app, asset: "polis-macos-aarch64.zip", bundle: "Polis.app"} =
             Catalogue.spec(app, "macos-aarch64")

    assert %{method: :linux_script, install_dir: "/opt/polis", unit: "polis.service"} =
             Catalogue.spec(app, "linux-aarch64")

    assert app.data == %{
             windows: ["{localappdata}/PolisData"],
             macos: ["{home}/Library/Application Support/PolisData"],
             linux: ["/var/lib/polis"]
           }
  end

  test "what does not belong in a URL, a path or a command line is refused" do
    quoted = %{
      "method" => "velopack",
      "setup" => "a\" & calc",
      "package" => "p",
      "pack_id" => "P",
      "main_exe" => "p.exe",
      "window_class" => "P"
    }

    elsewhere = %{
      "method" => "linux_script",
      "asset" => "a.tar.gz",
      "folder" => "a",
      "install_dir" => "/var/lib/polis",
      "unit" => "a.service"
    }

    for bad <- [
          %{"repo" => "https://evil.example/x"},
          %{"repo" => "AuroraRyunix/../x/y"},
          %{"id" => "Polis; rm"},
          %{"mark" => "../../etc/passwd"},
          %{"accent" => ["red", "blue"]},
          %{"port" => 70_000},
          %{"layout" => "whatever"},
          %{"data" => %{"windows" => ["{localappdata}/../Everything"]}},
          %{"platforms" => %{"windows-x86_64" => quoted}},
          %{"platforms" => %{"linux-x86_64" => elsewhere}},
          %{"platforms" => %{"amiga-68k" => %{"method" => "portable"}}}
        ] do
      assert_raise ArgumentError, fn -> parse([entry(bad)]) end
    end
  end

  test "a pack id that names a data folder is refused, in any case" do
    data = %{"windows" => ["{localappdata}/polisapp"]}
    assert_raise ArgumentError, ~r/pack id PolisApp/, fn -> parse([entry(%{"data" => data})]) end
  end
end
